import Foundation
import AVFoundation
import Combine
import Translation

// MARK: - Pipeline overview
//
//   Mic ──▶ Denoise ──▶ SourcePipeline(mic) ──┐
//                       (recorder, SRTs)       │   chunk lifecycle
//                                              ├──▶ Pipeline.applyLifecycle
//   System ─▶ Denoise ─▶ SourcePipeline(sys) ──┤        │
//                       (recorder, SRTs)       │        ▼
//                                              │   @Published inflightChunks
//                                              │        │  on .completed
//                                              │        ▼
//                                              │   Translator (async, cached)
//                                              │        │  on result
//                                              │        ▼
//                                              └──▶ @Published sentences
//                                                       │  on prune/drop
//                                                       ▼
//                                                   TranscriptArchive (.jsonl,
//                                                   source-tagged) + per-source
//                                                   SubtitleArchives
//
// Both streams share one `WhisperCppTranscriber` (and its `whisper_full`
// invocations serialize via NSLock). The UI sees in-flight chunks as
// reserved rows that flip through .listening → .transcribing →
// .translating and graduate to a `Sentence` with the same UUID — so the
// SwiftUI row identity stays stable across the lifecycle.

@MainActor
final class Pipeline: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var sentences: [Sentence] = []

    /// Chunks that have been detected but haven't graduated to a final
    /// `Sentence` yet — reserved UI rows that show the live state of
    /// the pipeline (listening / transcribing / translating). When a
    /// chunk graduates, we append to `sentences` and remove from this
    /// list, both keyed by the same UUID so the row identity stays
    /// stable through the transition.
    @Published private(set) var inflightChunks: [InflightChunk] = []

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

    /// Non-protected sentence older than this is pruned. Tuned for
    /// "rows can scroll off the top before they disappear" — five
    /// minutes is enough for several screen-heights of history at
    /// normal conversational pace.
    var maxAgeSeconds: TimeInterval = 300

    /// Hard cap on retained sentences. Generous so the scrollback
    /// stays useful; pruning by age handles long sessions.
    var maxSentenceCount: Int = 50

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
    /// One per-stream pipeline per `SourceTag`. Each owns its recorder
    /// and per-source SRT writers. Held here so `stop()` can signal
    /// each one to drain its audio source, and so `recordSentence`
    /// can route per-source SRT writes to the right files.
    private var sourcePipelines: [SourceTag: SourcePipeline] = [:]
    /// Live merged-SRT writers, one per language. Updated whenever a
    /// sentence graduates so the file on disk tracks the session in
    /// real time. `MKVExporter` reads from these at session end —
    /// it doesn't re-merge.
    private var mergedSubtitles: [String: MergedSubtitleArchive] = [:]
    /// Where session artifacts live during the run + where the final
    /// zip lands. Captured at run start so the cleanup path can read
    /// it after `defer` clears the rest of the state.
    private var currentOutputs: Paths.Outputs?

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

        // Wire the transcriber's per-chunk lifecycle callback. The
        // accumulator + worker invoke it from background tasks;
        // `handleChunkLifecycle` hops to MainActor and runs the state
        // machine (inflight bookkeeping + graduation to Sentence +
        // translation dispatch).
        if let w = whisperTranscriber as? WhisperCppTranscriber {
            w.onChunkLifecycle = { [weak self] id, source, event in
                self?.handleChunkLifecycle(id: id, source: source, event: event)
            }
        }
    }

    // MARK: - Chunk lifecycle handler

    /// Receives lifecycle events from `WhisperCppTranscriber` (called
    /// from off-MainActor tasks). All state mutation happens inside
    /// the `Task { @MainActor in ... }` so SwiftUI sees a single
    /// coherent change per event.
    nonisolated private func handleChunkLifecycle(
        id: UUID, source: SourceTag, event: WhisperCppTranscriber.ChunkLifecycle
    ) {
        Task { @MainActor in
            self.applyLifecycle(id: id, source: source, event: event)
        }
    }

    /// MainActor-isolated state-machine for one chunk's lifecycle.
    /// Maintains `inflightChunks` and graduates completed chunks
    /// (plus their translation, if any) to `sentences`.
    private func applyLifecycle(
        id: UUID, source: SourceTag, event: WhisperCppTranscriber.ChunkLifecycle
    ) {
        switch event {
        case .listening:
            // Reserve a row at voice onset. UI shows "listening".
            inflightChunks.append(InflightChunk(
                id: id, source: source, startedAt: Date(), state: .listening
            ))

        case .transcribing:
            // Chunk closed, whisper running. UI flips to "transcribing".
            if let idx = inflightChunks.firstIndex(where: { $0.id == id }) {
                inflightChunks[idx].state = .transcribing
            }

        case .completed(let text, let startSeconds, let endSeconds):
            // Whisper produced text. Either graduate immediately (no
            // translation needed / cached) or flip to "translating"
            // and dispatch the translator.
            let createdAt = startSeconds.map { runStartedAt.addingTimeInterval($0) } ?? Date()
            let endedAt = endSeconds.map { runStartedAt.addingTimeInterval($0) } ?? createdAt
            let srcLang = String(self.source.identifier.prefix(2))
            let tgtLang = self.target.code
            Log.line("lifecycle[\(source.rawValue)]: completed id=\(id.uuidString.prefix(8)) \"\(text.prefix(40))\" → \(srcLang)→\(tgtLang)")

            if srcLang == tgtLang {
                graduate(id: id, source: source, text: text, translation: text,
                         createdAt: createdAt, endsAt: endedAt)
                return
            }
            if let cached = translationCache[text] {
                Log.line("lifecycle[\(source.rawValue)]: cached translation hit for id=\(id.uuidString.prefix(8))")
                graduate(id: id, source: source, text: text, translation: cached,
                         createdAt: createdAt, endsAt: endedAt)
                return
            }
            // Need to translate. Mark "translating" and dispatch.
            if let idx = inflightChunks.firstIndex(where: { $0.id == id }) {
                inflightChunks[idx].state = .translating(text: text)
                Log.line("lifecycle[\(source.rawValue)]: state → translating, dispatching translator (id=\(id.uuidString.prefix(8)))")
            }
            // Explicit `@MainActor` on the Task closure so isolation
            // doesn't depend on Swift 5 inheritance heuristics. The
            // translator is @MainActor too; avoiding actor hops mid-
            // task is what makes the post-await `graduate` reliably
            // mutate `@Published` state on the right actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let translated = try await self.translator.translate(text)
                    Log.line("lifecycle[\(source.rawValue)]: translator returned for id=\(id.uuidString.prefix(8)): \"\(translated.prefix(40))\"")
                    self.cacheTranslation(source: text, translated: translated)
                    self.graduate(id: id, source: source, text: text, translation: translated,
                                  createdAt: createdAt, endsAt: endedAt)
                } catch {
                    Log.line("lifecycle[\(source.rawValue)]: translator error for id=\(id.uuidString.prefix(8)): \(error.localizedDescription)")
                    // Graduate with empty translation so the user still
                    // sees the transcription text — they can re-run for
                    // a retry.
                    self.graduate(id: id, source: source, text: text, translation: "",
                                  createdAt: createdAt, endsAt: endedAt)
                }
            }

        case .dropped:
            // Chunk filtered out by the worker (no voice, too short,
            // empty whisper output). No sentence to graduate; just
            // drop the inflight row.
            inflightChunks.removeAll { $0.id == id }
        }
    }

    /// Turn an inflight chunk into a `Sentence`. The Sentence gets a
    /// **fresh** UUID — reusing the chunk's UUID would collide with
    /// the inflight row's `.id()` in SwiftUI's LazyVStack and break
    /// the row swap. The sentence is also archived immediately to
    /// JSONL + per-source SRT + merged SRT(s) so the work-dir files
    /// stay live throughout the session (not just at end).
    private func graduate(
        id: UUID, source: SourceTag, text: String, translation: String,
        createdAt: Date, endsAt: Date
    ) {
        let sentence = Sentence(
            id: UUID(), text: text, translation: translation, source: source,
            createdAt: createdAt, endsAt: endsAt, lastModified: Date()
        )
        sentences.append(sentence)
        inflightChunks.removeAll { $0.id == id }
        recordSentence(sentence)
        enforceMaxCount()
    }

    /// Write a freshly-graduated sentence to every persistent output:
    /// shared JSONL, per-source SRTs (via `SourcePipeline.archiveSRT`),
    /// and per-language merged SRTs (with `[Mic]` / `[Sys]` prefix).
    /// All writes are queue-backed so this returns immediately.
    private func recordSentence(_ s: Sentence) {
        archive?.append(s)
        let prefix = "[\(s.source.shortLabel)]"
        let start = s.createdAt.timeIntervalSince(runStartedAt)
        let end = max(start, s.endsAt.timeIntervalSince(runStartedAt))
        sourcePipelines[s.source]?.archiveSRT(s)
        // Source-language merged: always.
        let srcLang = String(source.identifier.prefix(2))
        mergedSubtitles[srcLang]?.add(text: s.text, prefix: prefix, startSeconds: start, endSeconds: end)
        // Target-language merged: only if translation present and
        // distinct from source. Otherwise we'd write the same text
        // twice or write into the same file.
        let tgtLang = target.code
        if tgtLang != srcLang, !s.translation.isEmpty {
            mergedSubtitles[tgtLang]?.add(text: s.translation, prefix: prefix, startSeconds: start, endSeconds: end)
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
        inflightChunks = []
    }

    /// Load a canned set of mic/system sentences into the UI for
    /// screenshots and visual-regression checks. Triggered from the
    /// macOS menu bar (`Debug → Load fixture sentences`). Doesn't
    /// touch the audio pipeline; appends directly to `sentences`.
    func loadDebugFixtures() {
        let now = Date()
        // (source, transcription, translation)
        let fixtures: [(SourceTag, String, String)] = [
            (.mic, "Ich spreche diesen Text auf Deutsch",
             "I'm speaking this text in German"),
            (.mic, "Alles, was ich sage oder was der PC ausgibt, wird live ins Englische übersetzt",
             "Everything I say or what the PC outputs is translated live into English"),
            (.system, "Hallo, dies ist ein test audio playback",
             "Hello, this is a test audio playback"),
            (.mic, "Der Text wird auch in eine Datei geschrieben, die ich später auslesen kann",
             "The text is also written in a file that I can read later"),
        ]
        for (i, (source, text, translation)) in fixtures.enumerated() {
            let created = now.addingTimeInterval(Double(i) * 2)
            sentences.append(Sentence(
                id: UUID(), text: text, translation: translation, source: source,
                createdAt: created, endsAt: created.addingTimeInterval(1.5),
                lastModified: created
            ))
        }
    }

    /// The View calls this from `.translationTask` to hand us a fresh
    /// `TranslationSession`. Hides the AppleTranslator downcast.
    func installTranslationSession(_ session: TranslationSession?) {
        (translator as? AppleTranslator)?.setSession(session)
    }

    /// Block until queued writes hit disk. Sentences are already
    /// archived on graduate (`recordSentence`); this just awaits the
    /// per-writer dispatch queues so nothing is in flight when the
    /// process exits. Safe to call from `applicationWillTerminate`.
    func flushPendingSentences() {
        archive?.flush()
        for sp in sourcePipelines.values { sp.flush() }
        for merged in mergedSubtitles.values { merged.flush() }
    }

    // MARK: - Run loop

    private func run() async {
        isActive = true
        // The defer only clears terminal state. Disk flushes + MKV +
        // zip happen explicitly below so the exporter and zipper see
        // complete files.
        defer {
            if case .stopped = status { } else { status = .idle }
            runTask = nil
            isActive = false
            archive = nil
            sourcePipelines.removeAll()
            mergedSubtitles.removeAll()
            currentOutputs = nil
            inflightChunks.removeAll()
            if restartRequested {
                restartRequested = false
                sentences = []
                runTask = Task { await run() }
            }
        }

        // 1. Mic permission. (SCK prompts on its own when capture starts.)
        status = .requestingPermissions
        let micGranted: Bool = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        guard micGranted else { status = .stopped(reason: "Microphone permission denied"); return }

        // 2. Per-stream `DenoisingAudioSource`s. The mic instance gets
        //    a crosstalk gate that queries the transcriber's
        //    `lastSystemVoicedAt` and zeros the buffer when system was
        //    recently voiced. Applied upstream of the broadcaster so
        //    BOTH consumers (AudioRecorder + transcriber accumulator)
        //    see the same muted audio — without this, `.mic.wav` still
        //    had the raw speaker bleed even though the transcript
        //    suppressed it.
        let whisper = self.transcriber as? WhisperCppTranscriber
        let micDenoised = DenoisingAudioSource(
            micSource,
            label: "mic",
            muteWhen: { [weak whisper] in whisper?.isSystemRecentlyVoiced() ?? false }
        )
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

        // 3. Open output files. All session artifacts go into a temp
        //    work dir; we zip + delete it after the MKV is built.
        runStartedAt = Date()
        let srcLangCode = String(source.identifier.prefix(2))
        let tgtLangCode = target.code
        let outputs: Paths.Outputs
        do {
            outputs = try Paths.newRunOutputs(now: runStartedAt)
            archive = try TranscriptArchive(at: outputs.transcript)
        } catch {
            Log.line("Pipeline: opening work dir failed: \(error.localizedDescription)")
            for src in denoised.values { await src.stop() }
            status = .stopped(reason: "Output: \(error.localizedDescription)")
            return
        }
        currentOutputs = outputs

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
        // 4b. Open live merged-SRT archives, one per distinct language.
        let allLangs: [String] = (srcLangCode == tgtLangCode) ? [srcLangCode] : [srcLangCode, tgtLangCode]
        for lang in allLangs {
            if let merged = try? MergedSubtitleArchive(at: outputs.mergedSubtitle(lang)) {
                mergedSubtitles[lang] = merged
            }
        }
        Log.line("Run outputs: \(outputs.workDir.path) → \(outputs.zipDestination.lastPathComponent)")

        status = .running

        // 5. Background prune loop (the translation worker is gone —
        //    translation happens inline in the lifecycle handler).
        //    Cancellable separately from the audio path.
        let backgroundTask = Task {
            await self.runPruneLoop()
        }

        // 6. Run each SourcePipeline. They emit chunk lifecycle events
        //    via the WhisperCppTranscriber callback; UI state is
        //    managed in `applyLifecycle` (graduation, translation).
        Log.line("Pipeline: entering audio-path TaskGroup with \(sourcePipelines.count) pipelines")
        await withTaskGroup(of: Void.self) { group in
            for sp in sourcePipelines.values {
                group.addTask { await sp.run() }
            }
        }
        Log.line("All source pipelines drained")

        // 7. Cancel background workers and wait.
        backgroundTask.cancel()
        _ = await backgroundTask.value

        // 8. Final audio cleanup. Each `stop()` is idempotent.
        for sp in sourcePipelines.values { await sp.stop() }

        // 9. Finalize: flush writers, build MKV, zip work dir → docs.
        //    UI shows a spinner throughout. Sentences themselves are
        //    already archived (`recordSentence` ran on each graduate),
        //    so flushing just awaits the disk queues to drain.
        status = .finalizing
        archive?.flush()
        for sp in sourcePipelines.values { sp.flush() }
        for merged in mergedSubtitles.values { merged.flush() }
        Log.line("Pipeline: finalize — writers flushed, building MKV")
        await MKVExporter.export(outputs: outputs, langs: allLangs)
        Log.line("Pipeline: packing \(outputs.shippedFiles.count) files → \(outputs.zipDestination.lastPathComponent)")
        await ZipArchiver.zipFilesAndCleanup(
            outputs.shippedFiles,
            into: outputs.zipDestination,
            workDir: outputs.workDir
        )
    }

    // MARK: - Translation cache

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

    /// We never drop the most-recent sentence so the UI is never empty
    /// mid-stream. Returned as a `Set<UUID>` so callers can use it as
    /// a quick membership check inside a loop.
    private func protectedIDs() -> Set<UUID> {
        guard let id = sentences.last?.id else { return [] }
        return [id]
    }

    private func prune() {
        let protected = protectedIDs()
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        var i = sentences.count - 1
        while i >= 0 {
            let s = sentences[i]
            if !protected.contains(s.id) && s.lastModified < cutoff {
                sentences.remove(at: i)
            }
            i -= 1
        }
    }

    private func enforceMaxCount() {
        while sentences.count > maxSentenceCount {
            let protected = protectedIDs()
            if let i = sentences.firstIndex(where: { !protected.contains($0.id) }) {
                sentences.remove(at: i)
            } else {
                break
            }
        }
    }
}
