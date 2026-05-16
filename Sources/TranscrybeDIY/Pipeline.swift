import Foundation
import AVFoundation
import Speech
import Combine
import Translation

// MARK: - Pipeline overview
//
//   Mic ──buffers──▶ Transcriber ──SessionSnapshot──┐
//                                                    ├─▶ Pipeline.ingest(_, kind)
//   System audio ─▶ Transcriber ──SessionSnapshot──┘
//                                                    │
//                                                    ▼
//                                            @Published sentences: [Sentence]
//                                                    │       ▲
//                                                    │       │  writes translation back
//                                                    ▼       │
//                                            Translator (per-sentence, cached,
//                                              only when stable or final)
//                                                    │
//                                                    └─▶ TranscriptArchive (.jsonl)
//                                                          when sentence is dropped
//
// Why dual sources?
//   Live conversations and video streams often want both: the user's voice
//   (mic) and system audio (e.g. a foreign-language video they're watching).
//   The two run concurrently — each gets its own recognition cycle. Sentences
//   are tagged with their `kind` so the UI can color them differently.
//
// Why snapshots from the transcriber?
//   The recognizer occasionally revises an earlier sentence boundary (e.g.
//   removes a period it speculatively placed). A snapshot diff handles
//   "new sentence appeared", "live sentence grew", and "boundary went away"
//   uniformly. An index-only update would leave orphan rows.
//
// Why per-sentence + debounced translation?
//   Apple's `TranslationSession.translate(_:)` is cheap, but translating
//   the same growing partial every 500 ms multiplies that cost by 10× for
//   no user benefit. We translate a sentence only when its text is stable
//   (no changes for ≥0.6 s) OR when it flips to `isFinal`. Translations
//   are also cached by source text so identical strings across sessions
//   are free.

@MainActor
final class Pipeline: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var sentences: [Sentence] = []

    // MARK: - User settings (persisted via @AppStorage-bridge keys)

    /// Which source(s) to capture. Both can be on simultaneously.
    @Published var micEnabled: Bool { didSet { defaults.set(micEnabled, forKey: K.micEnabled) } }
    @Published var systemEnabled: Bool { didSet { defaults.set(systemEnabled, forKey: K.systemEnabled) } }

    @Published var source: SourceLocale { didSet { persist(source, forKey: K.source) } }
    @Published var target: TargetLanguage { didSet { persist(target, forKey: K.target) } }
    @Published var translateEnabled: Bool { didSet { defaults.set(translateEnabled, forKey: K.translateEnabled) } }

    /// Non-protected sentence older than this is pruned.
    var maxAgeSeconds: TimeInterval = 10

    /// Hard cap on retained sentences across all sources. Kept tight — this
    /// is a rolling translation panel, not a transcript log.
    var maxSentenceCount: Int = 3

    /// Minimum quiet time before translating a non-final sentence. Stops us
    /// from re-translating partials on every recognizer tick.
    var translationStabilityDelay: TimeInterval = 0.6

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

    // MARK: - Stages (injectable for swapping backends)

    private let micSource: AudioSource
    private let systemSource: AudioSource
    private let transcriber: Transcriber
    private let translator: Translator

    // MARK: - Internal state

    /// Per-source IDs of sentences "owned" by the active recognition session.
    /// Stored as a dictionary so we can iterate over both sources uniformly.
    private var activeIDsBySource: [SentenceKind: [UUID]] = [:]

    /// Last snapshot seen per source. Used to short-circuit ingest when the
    /// recognizer emits an identical snapshot back-to-back (small win, but
    /// avoids hundreds of no-op array mutations per second).
    private var lastSnapshotBySource: [SentenceKind: SessionSnapshot] = [:]

    /// Translation cache keyed by source text. Bounded — see `cacheTranslation`.
    private var translationCache: [String: String] = [:]
    private let maxCacheEntries: Int = 200

    private var runTask: Task<Void, Never>?
    private var archive: TranscriptArchive?

    /// True from when `run()` enters until its cleanup completes. This is
    /// what the UI's Start/Stop button reflects. Distinct from `runTask`:
    /// `runTask` is non-nil even during the *cancellation wind-down*, so we
    /// can no-op a redundant Stop press without starting a fresh run.
    @Published private(set) var isActive: Bool = false

    var isRunning: Bool { isActive }

    // MARK: - Persistence

    private let defaults = UserDefaults.standard
    private enum K {
        static let micEnabled = "pipeline.micEnabled"
        static let systemEnabled = "pipeline.systemEnabled"
        static let translateEnabled = "pipeline.translateEnabled"
        static let source = "pipeline.source"
        static let target = "pipeline.target"
    }

    /// Encode a Codable value as JSON in UserDefaults. Cheap.
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

        // Restore persisted settings. UserDefaults.bool returns false for
        // missing keys, which is wrong for `micEnabled` (should default to
        // true) — guard via objectExists.
        let d = UserDefaults.standard
        self.micEnabled = d.object(forKey: K.micEnabled) as? Bool ?? true
        self.systemEnabled = d.object(forKey: K.systemEnabled) as? Bool ?? false
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
        // Intentionally NOT setting runTask = nil here. We let run()'s
        // cleanup clear it once children have actually finished. If we
        // nilled it now, a second Stop tap (or any toggle()) would see
        // runTask == nil during the wind-down window and start a fresh
        // run on top of the still-cleaning-up old one — which would
        // create a duplicate transcript archive file.
    }

    func clear() {
        sentences = []
        activeIDsBySource = [:]
        lastSnapshotBySource = [:]
    }

    /// Called by the View when SwiftUI's `.translationTask` hands us a
    /// fresh `TranslationSession`. The View shouldn't have to know that
    /// our translator is concretely `AppleTranslator` — this hides the
    /// downcast.
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
            activeIDsBySource = [:]
            lastSnapshotBySource = [:]
            archive = nil
        }

        // 1. Validate selection.
        guard micEnabled || systemEnabled else {
            status = .stopped(reason: "No input source enabled — turn on Mic or System audio.")
            return
        }

        // 2. Permissions.
        status = .requestingPermissions
        if micEnabled {
            let granted: Bool = await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            guard granted else { status = .stopped(reason: "Microphone permission denied"); return }
        }
        let speechAuth = await AppleSpeechTranscriber.requestAuthorization()
        guard speechAuth == .authorized else {
            status = .stopped(reason: "Speech recognition not authorized"); return
        }

        // 3. Audio sources.
        status = .starting
        do {
            if micEnabled { try await micSource.start() }
            if systemEnabled { try await systemSource.start() }
        } catch {
            status = .stopped(reason: "Audio: \(error.localizedDescription)"); return
        }

        // 4. Open archive file for this run.
        do { archive = try TranscriptArchive() }
        catch { Log.line("Pipeline: archive open failed: \(error.localizedDescription)") }

        status = .running

        // 5. All concurrent workers live inside a TaskGroup so cancellation
        //    of the parent (runTask) propagates to every child. With the
        //    previous unstructured `Task { ... }` children, cancel() didn't
        //    reach them — recognition kept running after Stop, and a second
        //    Stop press would actually start a fresh run on top.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runTranslationLoop() }
            group.addTask { await self.runPruneLoop() }
            if micEnabled {
                group.addTask { await self.runRecognitionCycle(kind: .microphone) }
            }
            if systemEnabled {
                group.addTask { await self.runRecognitionCycle(kind: .systemAudio) }
            }
        }

        // 6. Audio cleanup is awaited so the next Start sees fully-stopped
        //    sources. Previously this was fire-and-forget which could race
        //    a rapid Stop→Start.
        await micSource.stop()
        await systemSource.stop()
    }

    /// Recognition cycle for one audio source. Keeps re-starting sessions
    /// until cancelled, or until 6 consecutive fast-fails (typically the
    /// language model isn't installed, or no audio is reaching the recognizer).
    private func runRecognitionCycle(kind: SentenceKind) async {
        var sessionIndex = 0
        var consecutiveFastFails = 0
        let maxFastFails = 6
        let fastFailThreshold: TimeInterval = 1.0

        while !Task.isCancelled {
            sessionIndex += 1
            activeIDsBySource[kind] = []
            lastSnapshotBySource[kind] = nil
            let started = Date()
            Log.line("[\(kind.archiveTag)] session #\(sessionIndex) starting locale=\(source.identifier)")

            // CRITICAL: subscribe to a *fresh* buffer stream per session.
            // Previously this was hoisted out of the loop and shared across
            // sessions — but AsyncStream is single-consumer, so after one
            // session's pump task drained the iterator, subsequent sessions
            // got no audio and hit "No speech detected" within 50 ms.
            let audio = sourceFor(kind: kind).buffers

            // When both audio sources are running, Apple's on-device
            // recognizer is single-instance — concurrent on-device sessions
            // both fast-fail with "No speech detected". Resolution: mic
            // keeps on-device (low latency, private); system gets routed
            // to the server. When only one source is enabled, both paths
            // can use on-device freely.
            let allowOnDevice = !(micEnabled && systemEnabled) || kind == .microphone

            do {
                for try await snapshot in transcriber.transcribe(
                    audio: audio, locale: source, allowOnDevice: allowOnDevice
                ) {
                    if Task.isCancelled { break }
                    ingest(snapshot, kind: kind)
                }
            } catch is CancellationError {
                // Expected on Stop — fall through to cleanup.
            } catch {
                Log.line("[\(kind.archiveTag)] session #\(sessionIndex) error: \(error.localizedDescription)")
            }

            // Mark this session's sentences final.
            for id in activeIDsBySource[kind] ?? [] {
                if let idx = sentences.firstIndex(where: { $0.id == id }) {
                    sentences[idx].isFinal = true
                }
            }
            activeIDsBySource[kind] = []

            let lifetime = Date().timeIntervalSince(started)
            consecutiveFastFails = (lifetime < fastFailThreshold) ? consecutiveFastFails + 1 : 0
            Log.line("[\(kind.archiveTag)] session #\(sessionIndex) ended after \(String(format: "%.2f", lifetime))s, fastFails=\(consecutiveFastFails)")

            if consecutiveFastFails >= maxFastFails {
                status = .stopped(reason: "[\(kind.archiveTag)] recognizer keeps failing — check Dictation install or input audio.")
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func sourceFor(kind: SentenceKind) -> AudioSource {
        kind == .microphone ? micSource : systemSource
    }

    /// Reconcile a snapshot against `sentences` for the given source:
    /// new entries → new Sentence with fresh UUID; existing entries →
    /// text/isFinal updated in place (stable UUID); missing entries
    /// (snapshot shrank) → those Sentences are removed.
    private func ingest(_ snapshot: SessionSnapshot, kind: SentenceKind) {
        // Short-circuit identical snapshots — the recognizer sometimes
        // emits the same state twice in a row.
        if snapshot == lastSnapshotBySource[kind] { return }
        lastSnapshotBySource[kind] = snapshot

        var active = activeIDsBySource[kind] ?? []
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
                // If the sentence was already dropped under us by the prune
                // pass (rare), we skip; the active[i] entry stays as a
                // tombstone that maps to nothing.
            } else {
                let new = Sentence(
                    id: UUID(),
                    kind: kind,
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

        activeIDsBySource[kind] = active
        enforceMaxCount()
    }

    // MARK: - Translation worker

    /// Translates sentences that have changed AND are either final or
    /// stable (no text change in the last `translationStabilityDelay`).
    /// Cached by source text so identical strings re-use a previous result.
    private func runTranslationLoop() async {
        Log.line("Translation loop started")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard translateEnabled else { continue }

            // Snapshot eligible work. Filter out empties + already-translated
            // + actively-growing partials.
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
                    break  // session not yet handed to us — try later
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
        // Cheap LRU-ish: drop ~10% oldest by insertion order when over cap.
        // Swift Dictionary preserves insertion order in practice.
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
    ///   - each source's live (last-active) sentence
    /// Earlier session-active sentences are eligible to drop — if the
    /// recognizer's next snapshot still references them, ingest finds no
    /// matching UUID and silently skips, so the drop sticks.
    private func protectedIDs() -> Set<UUID> {
        var s = Set<UUID>()
        if let id = sentences.last?.id { s.insert(id) }
        for (_, ids) in activeIDsBySource {
            if let id = ids.last { s.insert(id) }
        }
        return s
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        // Back-to-front so removals don't invalidate indices we still need.
        var i = sentences.count - 1
        while i >= 0 {
            let s = sentences[i]
            // protectedIDs() is recomputed each iteration so the changing
            // "last" sentence after a drop is reflected.
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
                break  // everything's protected
            }
        }
    }

    /// Single point that handles sentence removal: archives, then drops.
    /// Always use this rather than `sentences.remove(at:)` directly.
    private func dropSentence(at idx: Int) {
        archive?.append(sentences[idx])
        sentences.remove(at: idx)
    }
}
