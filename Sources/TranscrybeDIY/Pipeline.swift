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

    @Published var source: SourceLocale { didSet { persist(source, forKey: K.source) } }
    @Published var target: TargetLanguage { didSet { persist(target, forKey: K.target) } }
    @Published var translateEnabled: Bool { didSet { defaults.set(translateEnabled, forKey: K.translateEnabled) } }

    /// Non-protected sentence older than this is pruned. Generous — old
    /// sentences are dimmed in the UI but still readable, so we'd rather
    /// keep them around for re-reading than aggressively churn.
    var maxAgeSeconds: TimeInterval = 60

    /// Hard cap on retained sentences. Higher than feels tight on purpose:
    /// older sentences are pruned by age anyway; this cap only kicks in
    /// during very fast speech.
    var maxSentenceCount: Int = 8

    /// Minimum quiet time before translating a non-final sentence. Set to
    /// zero: translate eagerly. The cache (lastTranslatedSource) keeps us
    /// from re-sending identical text. The recognizer's partial rate is
    /// modest enough that translating each unique partial is cheap.
    var translationStabilityDelay: TimeInterval = 0

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

    /// IDs of sentences currently "owned" by the active recognition session.
    /// Snapshot diffs reconcile against this list.
    private var activeIDs: [UUID] = []

    /// Last snapshot seen — used to short-circuit ingest when the
    /// recognizer emits an identical snapshot back-to-back.
    private var lastSnapshot: SessionSnapshot?

    /// Translation cache keyed by source text. Bounded.
    private var translationCache: [String: String] = [:]
    private let maxCacheEntries: Int = 200

    private var runTask: Task<Void, Never>?
    private var archive: TranscriptArchive?

    // MARK: - Persistence

    private let defaults = UserDefaults.standard
    private enum K {
        static let translateEnabled = "pipeline.translateEnabled"
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
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
        self.translator = translator ?? AppleTranslator()

        self.availableSources = SFSpeechRecognizer.supportedLocales()
            .map { SourceLocale(identifier: $0.identifier) }
            .sorted { $0.identifier < $1.identifier }

        let d = UserDefaults.standard
        self.translateEnabled = d.object(forKey: K.translateEnabled) as? Bool ?? true
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
        runTask?.cancel()
        // Don't nil runTask here — let run()'s defer do it after the
        // wind-down completes, so a redundant Stop press is a no-op
        // instead of starting a fresh run on top.
    }

    func clear() {
        sentences = []
        activeIDs = []
        lastSnapshot = nil
    }

    /// The View calls this from `.translationTask` to hand us a fresh
    /// `TranslationSession`. Hides the AppleTranslator downcast.
    func installTranslationSession(_ session: TranslationSession?) {
        (translator as? AppleTranslator)?.setSession(session)
    }

    // MARK: - Run loop

    private func run() async {
        isActive = true
        defer {
            if case .stopped = status { } else { status = .idle }
            runTask = nil
            isActive = false
            activeIDs = []
            lastSnapshot = nil
            archive = nil
        }

        // 1. Permissions. Mic via TCC up front; SCK prompts on its own when
        //    the stream starts. Both are mandatory — the app always mixes
        //    mic + system audio so the user can talk and translate ambient
        //    audio (videos, calls) without choosing one.
        status = .requestingPermissions
        let micGranted: Bool = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        guard micGranted else { status = .stopped(reason: "Microphone permission denied"); return }
        let speechAuth = await AppleSpeechTranscriber.requestAuthorization()
        guard speechAuth == .authorized else {
            status = .stopped(reason: "Speech recognition not authorized"); return
        }

        // 2. Active source is always the mixed mic+system stream.
        let active: AudioSource = MixedAudioSource(micSource, systemSource)

        // 3. Start audio.
        status = .starting
        do {
            try await active.start()
        } catch {
            status = .stopped(reason: "Audio: \(error.localizedDescription)"); return
        }

        // 4. Archive file for this run.
        do { archive = try TranscriptArchive() }
        catch { Log.line("Pipeline: archive open failed: \(error.localizedDescription)") }

        status = .running

        // 5. Workers in a TaskGroup so cancellation cascades. Only ONE
        //    recognition cycle — that's the whole point of mixing.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runTranslationLoop() }
            group.addTask { await self.runPruneLoop() }
            group.addTask { await self.runRecognitionCycle(audio: active) }
        }

        // 6. Audio cleanup. Awaited so the next Start sees a clean source.
        await active.stop()
    }

    /// One recognition cycle, restarting sessions as they end. Bails after
    /// 6 consecutive fast-fails (typically the language model isn't installed,
    /// or no audio is reaching the recognizer).
    private func runRecognitionCycle(audio source: AudioSource) async {
        var sessionIndex = 0
        var consecutiveFastFails = 0
        let maxFastFails = 6
        let fastFailThreshold: TimeInterval = 1.0

        while !Task.isCancelled {
            sessionIndex += 1
            activeIDs = []
            lastSnapshot = nil
            let started = Date()
            Log.line("Session #\(sessionIndex) starting locale=\(self.source.identifier)")

            // CRITICAL: fresh buffer subscription per session. `.buffers`
            // is a fresh-subscription factory; AsyncStream is single-
            // consumer, so caching across sessions silently breaks restarts.
            let audio = source.buffers

            do {
                for try await snapshot in transcriber.transcribe(audio: audio, locale: self.source) {
                    if Task.isCancelled { break }
                    ingest(snapshot)
                }
            } catch is CancellationError {
                // Expected on Stop — fall through to cleanup.
            } catch {
                Log.line("Session #\(sessionIndex) error: \(error.localizedDescription)")
            }

            // Mark this session's sentences final.
            for id in activeIDs {
                if let idx = sentences.firstIndex(where: { $0.id == id }) {
                    sentences[idx].isFinal = true
                }
            }
            activeIDs = []

            let lifetime = Date().timeIntervalSince(started)
            consecutiveFastFails = (lifetime < fastFailThreshold) ? consecutiveFastFails + 1 : 0
            Log.line("Session #\(sessionIndex) ended after \(String(format: "%.2f", lifetime))s, fastFails=\(consecutiveFastFails)")

            if consecutiveFastFails >= maxFastFails {
                status = .stopped(reason: "Recognizer keeps failing — check Dictation install or input audio.")
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Reconcile a snapshot against `sentences`:
    /// new entries → new Sentence with fresh UUID;
    /// existing entries → text/isFinal updated in place (stable UUID);
    /// missing entries (snapshot shrank) → those Sentences are removed.
    private func ingest(_ snapshot: SessionSnapshot) {
        if snapshot == lastSnapshot { return }
        lastSnapshot = snapshot

        var active = activeIDs
        let now = Date()

        // 1. Truncate orphaned sentences (snapshot shrank).
        if snapshot.sentences.count < active.count {
            let dropping = Set(active[snapshot.sentences.count...])
            sentences.removeAll { dropping.contains($0.id) }
            active = Array(active.prefix(snapshot.sentences.count))
        }

        // 2. Update or append for each snapshot entry.
        for (i, sessionSentence) in snapshot.sentences.enumerated() {
            if i < active.count {
                let id = active[i]
                if let idx = sentences.firstIndex(where: { $0.id == id }) {
                    if sentences[idx].text != sessionSentence.text {
                        sentences[idx].text = sessionSentence.text
                        sentences[idx].lastModified = now
                    }
                    sentences[idx].isFinal = sessionSentence.isFinal
                }
            } else {
                let new = Sentence(
                    id: UUID(),
                    text: sessionSentence.text,
                    translation: "",
                    lastTranslatedSource: "",
                    lastModified: now,
                    isFinal: sessionSentence.isFinal
                )
                sentences.append(new)
                active.append(new.id)
            }
        }

        activeIDs = active
        enforceMaxCount()
    }

    // MARK: - Translation worker

    /// Translates sentences that have changed AND are either final or
    /// stable. Cached by source text.
    private func runTranslationLoop() async {
        Log.line("Translation loop started")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard translateEnabled else { continue }

            let now = Date()
            let pending: [(id: UUID, text: String)] = sentences.compactMap { s in
                guard !s.text.isEmpty,
                      s.text != s.lastTranslatedSource,
                      s.isFinal || now.timeIntervalSince(s.lastModified) >= translationStabilityDelay
                else { return nil }
                return (s.id, s.text)
            }

            for item in pending {
                if Task.isCancelled { break }

                if let cached = translationCache[item.text] {
                    applyTranslation(cached, to: item.id, originalSource: item.text)
                    continue
                }

                do {
                    let translated = try await translator.translate(item.text)
                    cacheTranslation(source: item.text, translated: translated)
                    applyTranslation(translated, to: item.id, originalSource: item.text)
                } catch TranslateError.noSession {
                    break
                } catch {
                    Log.line("Translation error: \(error.localizedDescription)")
                }
            }
        }
        Log.line("Translation loop exited")
    }

    private func applyTranslation(_ translated: String, to id: UUID, originalSource: String) {
        guard let idx = sentences.firstIndex(where: { $0.id == id }),
              sentences[idx].text == originalSource
        else { return }
        sentences[idx].translation = translated
        sentences[idx].lastTranslatedSource = originalSource
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

    /// Sentences we never drop:
    ///   - the most-recent sentence overall
    ///   - the live (last-active) sentence
    private func protectedIDs() -> Set<UUID> {
        var s = Set<UUID>()
        if let id = sentences.last?.id { s.insert(id) }
        if let id = activeIDs.last { s.insert(id) }
        return s
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
        archive?.append(sentences[idx])
        sentences.remove(at: idx)
    }
}
