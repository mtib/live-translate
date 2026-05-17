import Foundation
import AVFoundation
import Combine
import Translation

// MARK: - Pipeline overview
//
//   ┌──────────┐
//   │  Mic     │──┐
//   └──────────┘  │   (one source picked per run, based on toggles)
//                 ├─▶ AudioSource ──buffers──▶ Transcriber ──SessionSnapshot──▶ Pipeline
//   ┌──────────┐  │
//   │  System  │──┘
//   └──────────┘
//                                                  │
//                                                  ▼
//                                          @Published sentences: [Sentence]
//                                                  │       ▲
//                                                  ▼       │  writes translation back
//                                          Translator (per-sentence, cached,
//                                            only when stable or final)
//                                                  │
//                                                  └─▶ TranscriptArchive (.jsonl)
//                                                        when a sentence is dropped
//
// Why is there only ONE recognition cycle, even with two sources enabled?
//   Apple Speech serializes recognition tasks per-app. Two concurrent
//   recognizers (even one on-device, one server-side) preempt each other
//   on every restart — both fast-fail with "No speech detected" until one
//   gives up. Workaround: when both sources are enabled we wrap them in
//   `MixedAudioSource`, which merges their buffer streams into one. A
//   single recognizer sees the interleaved audio and we lose source
//   attribution as a trade-off.

@MainActor
final class Pipeline: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var sentences: [Sentence] = []

    /// Per-source "currently accumulating voiced audio into a chunk"
    /// signal — drives the mic icon in the UI top bar. Set by the
    /// transcriber's accumulator on voice onset; cleared on chunk
    /// close or audio-stream end.
    @Published private(set) var capturingVoice: [SourceTag: Bool] = [:]

    /// Per-source "whisper is currently running on a chunk from this
    /// stream" signal — drives the transcribing icon. Set by the
    /// worker when entering `whisper_full`; cleared on return.
    @Published private(set) var transcribingChunk: [SourceTag: Bool] = [:]

    /// Called from `WhisperCppTranscriber` callbacks (background
    /// tasks) to update the UI's busy state. Hops to MainActor to
    /// publish so the `@Published` write is safe.
    nonisolated func updateActivity(source: SourceTag, capturing: Bool? = nil, transcribing: Bool? = nil) {
        Task { @MainActor in
            if let capturing { self.capturingVoice[source] = capturing }
            if let transcribing { self.transcribingChunk[source] = transcribing }
        }
    }

    /// True from when `run()` enters until its cleanup completes.
    /// Drives the UI Start/Stop button.
    @Published private(set) var isActive: Bool = false
    var isRunning: Bool { isActive }

    // MARK: - User settings (persisted)

    /// Changing source/target while a run is in progress flushes the
    /// current run to disk and immediately starts a fresh one — new
    /// recording, new SRTs, new JSONL, clean visible history. The
    /// new run picks up the new language values when it opens its
    /// output files and starts its recognizer.
    @Published var source: SourceLocale {
        didSet {
            persist(source, forKey: K.source)
            if oldValue != source { requestRestartIfRunning() }
        }
    }
    @Published var target: TargetLanguage {
        didSet {
            persist(target, forKey: K.target)
            if oldValue != target { requestRestartIfRunning() }
        }
    }

    /// Non-protected sentence older than this is pruned. Generous — old
    /// sentences are dimmed in the UI but still readable, so we'd rather
    /// keep them around for re-reading than aggressively churn.
    var maxAgeSeconds: TimeInterval = 60

    /// Hard cap on retained sentences. Higher than feels tight on purpose:
    /// older sentences are pruned by age anyway; this cap only kicks in
    /// during very fast speech.
    var maxSentenceCount: Int = 8

    // MARK: - Available choices

    /// Curated BCP-47 locales available in the source-language picker.
    /// whisper.cpp accepts the 2-letter prefix of any of these (e.g.
    /// "de-DE" → "de"), so the region tag is purely for the macOS
    /// `Locale.localizedString(forIdentifier:)` to produce a nice
    /// display name like "German (Germany)". Reordered roughly by
    /// expected user popularity.
    let availableSources: [SourceLocale] = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT",
        "pt-PT", "pt-BR", "nl-NL", "da-DK", "sv-SE", "no-NO",
        "fi-FI", "pl-PL", "cs-CZ", "uk-UA", "ru-RU", "tr-TR",
        "el-GR", "he-IL", "ar-SA", "hi-IN", "th-TH", "vi-VN",
        "ja-JP", "ko-KR", "zh-CN", "zh-TW",
    ].map { SourceLocale(identifier: $0) }
    let availableTargets: [TargetLanguage] = [
        .init(code: "en", name: "English"), .init(code: "de", name: "German"),
        .init(code: "fr", name: "French"), .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"), .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"), .init(code: "da", name: "Danish"),
        .init(code: "sv", name: "Swedish"), .init(code: "ja", name: "Japanese"),
        .init(code: "zh-Hans", name: "Chinese (Simplified)"),
        .init(code: "ko", name: "Korean"), .init(code: "ru", name: "Russian"),
        .init(code: "ar", name: "Arabic"), .init(code: "hi", name: "Hindi"),
    ]

    // MARK: - Stages

    private let micSource: AudioSource
    private let systemSource: AudioSource
    private let transcriber: Transcriber
    private let translator: Translator

    // MARK: - Internal state

    /// Translation cache keyed by source text. Bounded.
    private var translationCache: [String: String] = [:]
    private let maxCacheEntries: Int = 200

    private var runTask: Task<Void, Never>?
    /// Shared JSONL archive — sentences from all sources interleave
    /// here, distinguished by the `source` field.
    private var archive: TranscriptArchive?
    /// One per-stream pipeline per `SourceTag`. Each owns its denoiser,
    /// recorder, SRT writers, and emits Sentences via an AsyncStream.
    /// Held here so `stop()` can signal each one to drain.
    private var sourcePipelines: [SourceTag: SourcePipeline] = [:]

    /// Set by a settings-change observer; read by run()'s defer. When
    /// true after the current run winds down, defer spawns a fresh run.
    /// Cleared by `stop()` so a user-initiated Stop doesn't auto-restart.
    private var restartRequested: Bool = false
    /// Wall-clock instant the current run's recording started. Used to
    /// compute SRT cue offsets (`sentence.createdAt - runStartedAt`).
    private var runStartedAt: Date = .distantPast

    // MARK: - Persistence

    private let defaults = UserDefaults.standard
    private enum K {
        static let source = "pipeline.source"
        static let target = "pipeline.target"
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, defaultValue: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(T.self, from: data)
        else { return defaultValue }
        return v
    }

    init(
        micSource: AudioSource? = nil,
        systemSource: AudioSource? = nil,
        transcriber: Transcriber? = nil,
        translator: Translator? = nil
    ) {
        self.micSource = micSource ?? MicrophoneSource()
        self.systemSource = systemSource ?? SystemAudioSource()
        let whisperTranscriber = transcriber ?? WhisperCppTranscriber()
        self.transcriber = whisperTranscriber
        self.translator = translator ?? AppleTranslator()

        self.source = Self.load(SourceLocale.self, forKey: K.source,
                                defaultValue: SourceLocale(identifier: "de-DE"))
        self.target = Self.load(TargetLanguage.self, forKey: K.target,
                                defaultValue: TargetLanguage(code: "en", name: "English"))

        // Wire the transcriber's per-source activity callback to the
        // published dicts. WhisperCppTranscriber calls this from
        // background tasks; `updateActivity` hops to MainActor.
        if let w = whisperTranscriber as? WhisperCppTranscriber {
            w.onActivity = { [weak self] source, capturing, transcribing in
                self?.updateActivity(source: source, capturing: capturing, transcribing: transcribing)
            }
        }
    }

    // MARK: - Public controls

    func toggle() {
        if runTask != nil { stop() } else { runTask = Task { await run() } }
    }

    func stop() {
        Log.line("Pipeline.stop()")
        restartRequested = false
        stopActiveSources()
    }

    /// Called from the source/target property observers. Stops the
    /// audio sources so the current run drains naturally, then run()'s
    /// defer spawns a fresh replacement.
    private func requestRestartIfRunning() {
        guard runTask != nil else { return }
        Log.line("Pipeline.requestRestart() — settings changed mid-run")
        restartRequested = true
        stopActiveSources()
    }

    /// Graceful shutdown: stopping each source pipeline ends its
    /// audio broadcaster, which drains the per-stream accumulator +
    /// worker + recording loops. Without this, cancellation would
    /// abort the pipeline mid-flight and drop trailing audio.
    private func stopActiveSources() {
        for pipeline in sourcePipelines.values {
            Task { await pipeline.stop() }
        }
    }

    func clear() {
        sentences = []
    }

    /// The View calls this from `.translationTask` to hand us a fresh
    /// `TranslationSession`. Hides the AppleTranslator downcast.
    func installTranslationSession(_ session: TranslationSession?) {
        (translator as? AppleTranslator)?.setSession(session)
    }

    /// Flush every still-visible sentence to every output, then block
    /// briefly so queued writes (transcript + audio + SRTs) land on
    /// disk. Safe to call from `applicationWillTerminate`. Idempotent.
    func flushPendingSentences() {
        for s in sentences { archiveDrop(s) }
        archive?.flush()
        for sp in sourcePipelines.values { sp.flush() }
        sentences = []
    }

    // MARK: - Run loop

    private func run() async {
        isActive = true
        defer {
            for s in sentences { archiveDrop(s) }
            archive?.flush()
            for sp in sourcePipelines.values { sp.flush() }
            if case .stopped = status { } else { status = .idle }
            runTask = nil
            isActive = false
            archive = nil
            sourcePipelines.removeAll()
            if restartRequested {
                restartRequested = false
                sentences = []
                runTask = Task { await run() }
            }
        }

        // 1. Permissions.
        status = .requestingPermissions
        let micGranted: Bool = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        guard micGranted else { status = .stopped(reason: "Microphone permission denied"); return }

        // 2. Build per-stream `DenoisingAudioSource`s and start them in
        //    parallel. Each upstream goes through its own RNNoise; no
        //    mixing happens.
        let micDenoised = DenoisingAudioSource(micSource, label: "mic")
        let systemDenoised = DenoisingAudioSource(systemSource, label: "system")
        let denoised: [SourceTag: AudioSource] = [.mic: micDenoised, .system: systemDenoised]

        status = .starting
        do {
            async let m: Void = micDenoised.start()
            async let s: Void = systemDenoised.start()
            try await (m, s)
        } catch {
            status = .stopped(reason: "Audio: \(error.localizedDescription)"); return
        }

        // 3. Open output files. One shared JSONL; per-source WAVs and
        //    per-(source,language) SRTs.
        runStartedAt = Date()
        let srcLangCode = String(source.identifier.prefix(2))
        let tgtLangCode = target.code
        let outputs: Paths.Outputs
        do {
            outputs = try Paths.newRunOutputs(now: runStartedAt)
            archive = try TranscriptArchive(at: outputs.transcript)
        } catch {
            Log.line("Pipeline: opening JSONL archive failed: \(error.localizedDescription)")
            for src in denoised.values { await src.stop() }
            status = .stopped(reason: "Output: \(error.localizedDescription)")
            return
        }

        // 4. Build per-source pipelines with their own recorder + SRTs.
        for tag in SourceTag.allCases {
            guard let src = denoised[tag] else { continue }
            let recorder = try? AudioRecorder(at: outputs.recording(tag))
            let sourceSubs = try? SubtitleArchive(at: outputs.subtitle(tag, srcLangCode))
            let targetSubs: SubtitleArchive? = (srcLangCode == tgtLangCode)
                ? nil
                : try? SubtitleArchive(at: outputs.subtitle(tag, tgtLangCode))
            sourcePipelines[tag] = SourcePipeline(
                source: tag,
                audioSource: src,
                transcriber: self.transcriber,
                locale: self.source,
                runStartedAt: runStartedAt,
                recorder: recorder,
                sourceSubs: sourceSubs,
                targetSubs: targetSubs
            )
        }
        Log.line("Run outputs: \(outputs.timestamp) (.jsonl, 2 .wav, per-source SRTs)")

        status = .running

        // 5. Background workers (translation + prune): cancellable
        //    separately from the audio path.
        let backgroundTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.runTranslationLoop() }
                group.addTask { await self.runPruneLoop() }
            }
        }

        // 6. Run each SourcePipeline + a sentence-consumer that merges
        //    its emissions into the shared UI. All exit naturally when
        //    each pipeline's audio source stops.
        Log.line("Pipeline: entering audio-path TaskGroup with \(sourcePipelines.count) pipelines")
        await withTaskGroup(of: Void.self) { group in
            for (_, sp) in sourcePipelines {
                group.addTask { await sp.run() }
                group.addTask { await self.consumeSentences(from: sp) }
            }
        }
        Log.line("All source pipelines drained")

        // 7. Cancel background workers and wait.
        backgroundTask.cancel()
        _ = await backgroundTask.value

        // 8. Final audio cleanup. Each `stop()` is idempotent.
        for sp in sourcePipelines.values { await sp.stop() }
    }

    /// Consume one SourcePipeline's outgoing `Sentence` stream and
    /// append each to the shared visible list. Exits when the source
    /// pipeline finishes its stream.
    private func consumeSentences(from sp: SourcePipeline) async {
        Log.line("Pipeline: sentence consumer for \(sp.source.rawValue) started")
        var count = 0
        for await sentence in sp.sentences {
            count += 1
            Log.line("Pipeline: consumer[\(sp.source.rawValue)] got sentence #\(count): \"\(sentence.text.prefix(50))\"")
            self.sentences.append(sentence)
            enforceMaxCount()
        }
        Log.line("Pipeline: sentence consumer for \(sp.source.rawValue) exited (total \(count))")
    }

    /// One recognition cycle, restarting sessions as they end. Bails after
    /// 6 consecutive fast-fails (typically the language model isn't installed,
    /// or no audio is reaching the recognizer).
    // MARK: - Translation worker

    /// Translation worker. Each sentence's source text is immutable
    /// (whisper emits finals only), so each row needs exactly one
    /// translation pass. We walk newest-first so the freshest line on
    /// screen gets its translation first — older lines lag without
    /// blocking the live row.
    private func runTranslationLoop() async {
        Log.line("Translation loop started")
        while !Task.isCancelled {
            while !Task.isCancelled, let item = nextTranslationCandidate() {
                if let cached = translationCache[item.text] {
                    applyTranslation(cached, to: item.id, originalSource: item.text)
                    continue
                }
                do {
                    let translated = try await translator.translate(item.text)
                    cacheTranslation(source: item.text, translated: translated)
                    applyTranslation(translated, to: item.id, originalSource: item.text)
                } catch TranslateError.noSession {
                    break  // session not yet handed to us — wait it out
                } catch {
                    Log.line("Translation error: \(error.localizedDescription)")
                    break  // back off briefly rather than spinning on the error
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        Log.line("Translation loop exited")
    }

    /// Newest untranslated sentence, or nil if everything is done.
    private func nextTranslationCandidate() -> (id: UUID, text: String)? {
        for s in sentences.reversed() {
            if !s.text.isEmpty && s.translation.isEmpty {
                return (s.id, s.text)
            }
        }
        return nil
    }

    /// Apply a translation result to the sentence with `id`. Guards
    /// against a sentence that was pruned between dispatch and result
    /// landing. `originalSource` defends against rare ID reuse — only
    /// applies if the sentence still has the same source text we
    /// translated. Bumps `lastModified` (a prune-freshness signal),
    /// but never touches `createdAt` / `endsAt` — those are anchored
    /// to the actual audio span and must not drift.
    private func applyTranslation(_ translated: String, to id: UUID, originalSource: String) {
        guard let idx = sentences.firstIndex(where: { $0.id == id }),
              sentences[idx].text == originalSource
        else { return }
        sentences[idx].translation = translated
        sentences[idx].lastModified = Date()
    }

    private func cacheTranslation(source: String, translated: String) {
        translationCache[source] = translated
        // LRU-ish: drop ~10% oldest by insertion order when over cap.
        if translationCache.count > maxCacheEntries {
            let toDrop = translationCache.count - (maxCacheEntries * 9 / 10)
            for key in translationCache.keys.prefix(toDrop) {
                translationCache.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Prune

    private func runPruneLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            prune()
        }
    }

    /// We never drop the most-recent sentence. There's no separate
    /// "live" concept anymore — every sentence is final the moment it
    /// arrives, so age + cap is the only signal for eviction, with the
    /// newest entry held back so the UI is never empty mid-stream.
    private func protectedIDs() -> Set<UUID> {
        guard let id = sentences.last?.id else { return [] }
        return [id]
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        var i = sentences.count - 1
        while i >= 0 {
            let s = sentences[i]
            if !protectedIDs().contains(s.id) && s.lastModified < cutoff {
                dropSentence(at: i)
            }
            i -= 1
        }
    }

    private func enforceMaxCount() {
        while sentences.count > maxSentenceCount {
            let protected = protectedIDs()
            if let i = sentences.firstIndex(where: { !protected.contains($0.id) }) {
                dropSentence(at: i)
            } else {
                break
            }
        }
    }

    /// Single point that archives, then drops a sentence. Always use this
    /// rather than `sentences.remove(at:)` directly.
    private func dropSentence(at idx: Int) {
        archiveDrop(sentences[idx])
        sentences.remove(at: idx)
    }

    /// Fan one outgoing sentence to every writer: shared JSONL (with
    /// the sentence's source tag) and the matching per-source SRT
    /// files. Audio recorders are fed elsewhere — each SourcePipeline
    /// subscribes to its denoised broadcaster directly.
    private func archiveDrop(_ s: Sentence) {
        archive?.append(s)
        sourcePipelines[s.source]?.archiveSRT(s)
    }
}
