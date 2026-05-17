import Foundation
import AVFoundation
import Speech
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

    let availableSources: [SourceLocale]
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
    private var archive: TranscriptArchive?
    private var recorder: AudioRecorder?
    private var sourceSubs: SubtitleArchive?
    private var targetSubs: SubtitleArchive?

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
        self.transcriber = transcriber ?? WhisperCppTranscriber()
        self.translator = translator ?? AppleTranslator()

        // The locale list is still SFSpeechRecognizer's — it's a
        // convenient pre-built BCP-47 set, even though the active
        // transcriber backend (whisper.cpp) doesn't need Apple's
        // speech models. Whisper itself accepts any 2-letter prefix.
        self.availableSources = SFSpeechRecognizer.supportedLocales()
            .map { SourceLocale(identifier: $0.identifier) }
            .sorted { $0.identifier < $1.identifier }

        self.source = Self.load(SourceLocale.self, forKey: K.source,
                                defaultValue: SourceLocale(identifier: "de-DE"))
        self.target = Self.load(TargetLanguage.self, forKey: K.target,
                                defaultValue: TargetLanguage(code: "en", name: "English"))
    }

    // MARK: - Public controls

    func toggle() {
        if runTask != nil { stop() } else { runTask = Task { await run() } }
    }

    func stop() {
        Log.line("Pipeline.stop()")
        // Explicit user stop cancels any pending auto-restart from a
        // recent settings change.
        restartRequested = false
        runTask?.cancel()
        // Don't nil runTask here — let run()'s defer do it after the
        // wind-down completes, so a redundant Stop press is a no-op
        // instead of starting a fresh run on top.
    }

    /// Called from the source/target property observers. Cancels the
    /// in-flight run if any, flagging that the wind-down should spawn
    /// a fresh replacement. No-op when no run is active — the next
    /// manual Start already picks up the new settings.
    private func requestRestartIfRunning() {
        guard runTask != nil else { return }
        Log.line("Pipeline.requestRestart() — settings changed mid-run")
        restartRequested = true
        runTask?.cancel()
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
        sourceSubs?.flush()
        targetSubs?.flush()
        recorder?.flush()
        sentences = []
    }

    // MARK: - Run loop

    private func run() async {
        isActive = true
        defer {
            // Flush still-visible sentences to every output before letting
            // the writers drop, so a clean Stop persists in-flight content.
            for s in sentences { archiveDrop(s) }
            archive?.flush()
            sourceSubs?.flush()
            targetSubs?.flush()
            recorder?.flush()
            if case .stopped = status { } else { status = .idle }
            runTask = nil
            isActive = false
            archive = nil
            recorder = nil
            sourceSubs = nil
            targetSubs = nil
            // A settings change while we were running flagged
            // restartRequested and cancelled us. Spawn a fresh run
            // with a clean visible list (the just-flushed sentences
            // are already on disk).
            if restartRequested {
                restartRequested = false
                sentences = []
                runTask = Task { await run() }
            }
        }

        // 1. Permissions. Mic via TCC up front; SCK prompts on its own when
        //    the stream starts. Both are mandatory — the app always mixes
        //    mic + system audio so the user can talk and translate ambient
        //    audio (videos, calls) without choosing one. Speech-recognition
        //    permission is no longer requested — whisper.cpp runs locally
        //    against its own model and doesn't touch Apple's Speech APIs.
        status = .requestingPermissions
        let micGranted: Bool = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        guard micGranted else { status = .stopped(reason: "Microphone permission denied"); return }

        // 2. Active source is always the mixed mic+system stream.
        let active: AudioSource = MixedAudioSource(micSource, systemSource)

        // 3. Start audio.
        status = .starting
        do {
            try await active.start()
        } catch {
            status = .stopped(reason: "Audio: \(error.localizedDescription)"); return
        }

        // 4. Open paired output files for this run. JSONL + WAV + two
        //    SRT subtitle files (source and target language), all
        //    sharing the same timestamp stem.
        runStartedAt = Date()
        let srcLangCode = String(source.identifier.prefix(2))
        let tgtLangCode = target.code
        do {
            let outputs = try Paths.newRunOutputs(now: runStartedAt)
            archive = try TranscriptArchive(at: outputs.transcript)
            recorder = try AudioRecorder(at: outputs.recording)
            sourceSubs = try SubtitleArchive(at: outputs.subtitle(srcLangCode))
            // Skip target SRT if it would clobber the source one (same lang).
            if tgtLangCode != srcLangCode {
                targetSubs = try SubtitleArchive(at: outputs.subtitle(tgtLangCode))
            }
            Log.line("Run outputs: \(outputs.timestamp) (.jsonl, .wav, .\(srcLangCode).srt\(tgtLangCode == srcLangCode ? "" : ", .\(tgtLangCode).srt"))")
        } catch {
            Log.line("Pipeline: opening output files failed: \(error.localizedDescription)")
            archive = nil
            recorder = nil
            sourceSubs = nil
            targetSubs = nil
        }

        status = .running

        // 5. Workers in a TaskGroup so cancellation cascades. Only ONE
        //    recognition cycle — that's the whole point of mixing.
        //    A second consumer of `active.buffers` records the mixed
        //    audio to disk in parallel.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runTranslationLoop() }
            group.addTask { await self.runPruneLoop() }
            group.addTask { await self.runRecognitionCycle(audioSource: active) }
            group.addTask { await self.runRecordingLoop(audioSource: active) }
        }

        // 6. Audio cleanup. Awaited so the next Start sees a clean source.
        await active.stop()
    }

    /// One recognition cycle, restarting sessions as they end. Bails after
    /// 6 consecutive fast-fails (typically the language model isn't installed,
    /// or no audio is reaching the recognizer).
    /// Subscribes to the active audio source as a second consumer of its
    /// broadcaster and forwards every PCM buffer to `AudioRecorder`. The
    /// MixedAudioSource sample-sums mic + system, so what we write is the
    /// exact audio the recognizer sees — the .wav pairs 1:1 with the
    /// JSONL transcript by timestamp. Exits when the buffer stream ends.
    private func runRecordingLoop(audioSource: AudioSource) async {
        guard recorder != nil else { return }
        Log.line("Recording loop started")
        for await buf in audioSource.buffers {
            recorder?.append(buf)
        }
        Log.line("Recording loop exited")
    }

    /// Run one continuous transcription session for the lifetime of
    /// the audio source. The whisper.cpp backend's `transcribe()` is
    /// itself a long-lived call that internally pumps audio without
    /// pause and yields one snapshot per closed chunk, so the Pipeline
    /// just consumes that stream straight through. No outer loop is
    /// needed — re-subscribing would risk dropping audio while the
    /// previous subscription was being torn down.
    private func runRecognitionCycle(audioSource: AudioSource) async {
        let audio = audioSource.buffers
        do {
            for try await snapshot in transcriber.transcribe(audio: audio, locale: source) {
                if Task.isCancelled { break }
                ingest(snapshot)
            }
        } catch is CancellationError {
            // Expected on Stop — fall through to outer cleanup.
        } catch {
            Log.line("Transcribe error: \(error.localizedDescription)")
        }
    }

    /// Append every sentence in the snapshot as a new `Sentence`. No
    /// in-place edits, no UUID reuse — every snapshot represents fresh
    /// content from a closed chunk.
    private func ingest(_ snapshot: SessionSnapshot) {
        if snapshot.sentences.isEmpty { return }
        let now = Date()
        for ss in snapshot.sentences {
            let trimmed = ss.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sentences.append(Sentence(
                id: UUID(),
                text: trimmed,
                translation: "",
                createdAt: now,
                lastModified: now
            ))
        }
        enforceMaxCount()
    }

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
    /// translated.
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

    /// Fan one outgoing sentence to every writer: JSONL transcript, source
    /// SRT subtitle, target SRT subtitle (if the translation is present and
    /// the languages differ). The audio recorder is fed elsewhere (it
    /// consumes the buffer broadcaster directly).
    private func archiveDrop(_ s: Sentence) {
        archive?.append(s)
        let start = s.createdAt.timeIntervalSince(runStartedAt)
        let end = max(start, s.lastModified.timeIntervalSince(runStartedAt))
        sourceSubs?.append(text: s.text, startSeconds: start, endSeconds: end)
        if !s.translation.isEmpty {
            targetSubs?.append(text: s.translation, startSeconds: start, endSeconds: end)
        }
    }
}
