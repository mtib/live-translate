import Foundation
import AVFoundation
import Speech
import Combine

// MARK: - Pipeline overview
//
//   Mic ──buffers──▶ Transcriber ──SessionSnapshot──┐
//                                                    ├─▶ Pipeline.ingest(snapshot, kind)
//   System audio ─▶ Transcriber ──SessionSnapshot──┘
//                                                    │
//                                                    ▼
//                                            @Published sentences: [Sentence]
//                                                    │       ▲
//                                                    │       │ (writes translation back)
//                                                    ▼       │
//                                            Translator (per-sentence)
//                                                    │
//                                                    └─▶ translation cache [hash → String]
//
// Why dual sources?
//   Live conversations and video streams often want both: the user's voice
//   (mic) translated into a target language, AND the system audio (e.g.
//   foreign-language video they're watching). The two can run concurrently
//   because each gets its own SFSpeechRecognizer instance with its own
//   buffer pump. Sentences are tagged with their kind so the UI can color
//   them differently.
//
// Why snapshots from the transcriber?
//   The recognizer occasionally revises an earlier sentence boundary (e.g.
//   removes a period it speculatively placed). A snapshot diff handles both
//   "new sentence appeared" and "sentence boundary went away" uniformly —
//   the previous design's index-only update left orphan rows.
//
// Why a translation cache?
//   Identical sentences re-appear constantly across sessions (the recognizer
//   sometimes restarts mid-utterance, the same greeting gets repeated, etc.).
//   The cache means we pay Apple's Translation framework once per unique
//   string and reuse the result thereafter.

@MainActor
final class Pipeline: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var sentences: [Sentence] = []

    // MARK: - User settings

    /// Which source(s) to capture. Both can be on simultaneously.
    @Published var micEnabled: Bool = true
    @Published var systemEnabled: Bool = false

    @Published var source: SourceLocale = SourceLocale(identifier: "de-DE")
    @Published var target: TargetLanguage = TargetLanguage(code: "en", name: "English")
    @Published var translateEnabled: Bool = true

    /// A non-active, non-most-recent sentence older than this gets pruned.
    var maxAgeSeconds: TimeInterval = 10

    /// Hard cap on retained sentences across both sources. Kept tight on
    /// purpose: the UI is a rolling translation panel, not a transcript log.
    var maxSentenceCount: Int = 3

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

    // MARK: - Injected stages

    private let micSource: AudioSource
    private let systemSource: AudioSource
    let transcriber: Transcriber
    let translator: Translator

    // MARK: - Internal state

    /// Per-source state: the IDs of sentences currently "owned" by the
    /// active recognition session for that source. Snapshot diffs work
    /// against this list.
    private struct SourceRunState {
        var activeIDs: [UUID] = []
    }
    private var micState = SourceRunState()
    private var systemState = SourceRunState()

    /// Translation cache: source-text → translated-text. Bounded — entries
    /// drop out as sentences they were created for are pruned.
    private var translationCache: [String: String] = [:]
    private var maxCacheEntries: Int = 200

    private var runTask: Task<Void, Never>?

    /// File we append dropped sentences to during the current run. Created
    /// when the user clicks Start and reused for the lifetime of that run.
    /// Lives at `~/Documents/transcripts/<timestamp>.txt`.
    private var transcriptFileURL: URL?

    var isRunning: Bool {
        switch status {
        case .listening, .reconnecting, .starting, .requestingPermissions: return true
        default: return false
        }
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
    }

    // MARK: - Public controls

    func toggle() {
        if runTask != nil { stop() } else { runTask = Task { await run() } }
    }

    func stop() {
        Log.line("Pipeline.stop()")
        runTask?.cancel()
        runTask = nil
    }

    func clear() {
        sentences = []
        micState = .init()
        systemState = .init()
    }

    // MARK: - Run loop

    private func run() async {
        defer {
            micSource.stop()
            systemSource.stop()
            if case .stopped = status { } else { status = .idle }
            runTask = nil
            micState = .init()
            systemState = .init()
            transcriptFileURL = nil
        }

        // 1. Validate selection. At least one source must be enabled.
        guard micEnabled || systemEnabled else {
            status = .stopped(reason: "No input source enabled — turn on Mic or System audio.")
            return
        }

        // 2. Permissions. Mic via TCC up-front; SCK prompts itself on start.
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

        // 3. Start the audio sources we need.
        status = .starting
        do {
            if micEnabled { try await micSource.start() }
            if systemEnabled { try await systemSource.start() }
        } catch {
            status = .stopped(reason: "Audio: \(error.localizedDescription)"); return
        }

        // 3a. Open transcript archive file for this run.
        openTranscriptFile()

        // 4. Concurrent workers: per-source recognition cycle, plus translation + prune.
        let translationWorker = Task { await runTranslationLoop() }
        let pruneWorker = Task { await runPruneLoop() }
        defer {
            translationWorker.cancel()
            pruneWorker.cancel()
        }

        let micTask = micEnabled
            ? Task { await runRecognitionCycle(kind: .microphone) }
            : nil
        let systemTask = systemEnabled
            ? Task { await runRecognitionCycle(kind: .systemAudio) }
            : nil

        // 5. Wait for both to finish (cancellation or fatal failure).
        await micTask?.value
        await systemTask?.value
    }

    /// Recognition cycle for one audio source. Keeps re-starting sessions
    /// until cancelled or until 6 consecutive fast-fails (likely missing
    /// language model or no audio coming in).
    private func runRecognitionCycle(kind: SentenceKind) async {
        var sessionIndex = 0
        var consecutiveFastFails = 0
        let maxFastFails = 6
        let fastFailThreshold: TimeInterval = 1.0
        let audio = (kind == .microphone) ? micSource.buffers : systemSource.buffers

        while !Task.isCancelled {
            sessionIndex += 1
            // We don't surface per-source session indexes in status — just
            // the most-recent "Listening (...)" wins. Two sources running
            // simultaneously share the same status display.
            status = .listening(sessionIndex: sessionIndex, locale: source.identifier)
            clearActiveIDs(for: kind)
            let started = Date()
            Log.line("[\(kind.rawValue)] session #\(sessionIndex) starting locale=\(source.identifier)")

            do {
                for try await snapshot in transcriber.transcribe(audio: audio, locale: source) {
                    ingest(snapshot, kind: kind)
                }
            } catch {
                Log.line("[\(kind.rawValue)] session #\(sessionIndex) error: \(error.localizedDescription)")
            }

            // Mark this session's sentences final — text is committed.
            for id in activeIDs(for: kind) {
                if let idx = sentences.firstIndex(where: { $0.id == id }) {
                    sentences[idx].isFinal = true
                }
            }
            clearActiveIDs(for: kind)

            let lifetime = Date().timeIntervalSince(started)
            consecutiveFastFails = (lifetime < fastFailThreshold) ? consecutiveFastFails + 1 : 0
            Log.line("[\(kind.rawValue)] session #\(sessionIndex) ended after \(String(format: "%.2f", lifetime))s, fastFails=\(consecutiveFastFails)")

            if consecutiveFastFails >= maxFastFails {
                status = .stopped(reason: "[\(kind.rawValue)] recognizer keeps failing — check Dictation install or input audio.")
                return
            }
            if Task.isCancelled { return }
            status = .reconnecting
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Reconcile a snapshot against `sentences` for the given source. New
    /// snapshot entries become new Sentence rows; existing entries (matched
    /// by position within this session) update in place; entries that have
    /// disappeared from the snapshot are removed (handles "recognizer
    /// revised away a boundary" case).
    private func ingest(_ snapshot: SessionSnapshot, kind: SentenceKind) {
        var active = activeIDs(for: kind)
        let now = Date()

        // 1. Truncate orphaned sentences (snapshot shrunk).
        if snapshot.sentences.count < active.count {
            let dropping = active[snapshot.sentences.count...]
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

        setActiveIDs(active, for: kind)
        enforceMaxCount()
    }

    /// Translates dirty sentences. "Dirty" = text differs from lastTranslatedSource.
    /// Checks the translation cache first, so identical strings across
    /// sessions don't re-incur the Translation framework round-trip.
    private func runTranslationLoop() async {
        Log.line("Translation loop started")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard translateEnabled else { continue }

            let dirty = sentences
                .filter { !$0.text.isEmpty && $0.text != $0.lastTranslatedSource }
                .map { (id: $0.id, text: $0.text) }

            for item in dirty {
                if Task.isCancelled { break }

                if let cached = translationCache[item.text] {
                    applyTranslation(cached, toSentenceID: item.id, originalSource: item.text)
                    continue
                }

                do {
                    let translated = try await translator.translate(item.text, from: source, to: target)
                    cacheTranslation(source: item.text, translated: translated)
                    applyTranslation(translated, toSentenceID: item.id, originalSource: item.text)
                } catch TranslateError.noSession {
                    break  // session not yet handed to us — try later
                } catch {
                    Log.line("Translation error: \(error.localizedDescription)")
                }
            }
        }
        Log.line("Translation loop exited")
    }

    private func applyTranslation(_ translated: String, toSentenceID id: UUID, originalSource: String) {
        guard let idx = sentences.firstIndex(where: { $0.id == id }),
              sentences[idx].text == originalSource
        else { return }   // sentence vanished or text changed under us
        sentences[idx].translation = translated
        sentences[idx].lastTranslatedSource = originalSource
    }

    private func cacheTranslation(source: String, translated: String) {
        translationCache[source] = translated
        // Cheap LRU-ish: when over cap, drop ~10% oldest by insertion order.
        // Swift Dictionary preserves insertion order in practice but isn't
        // guaranteed — close enough for our purposes.
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
    ///   - the very last sentence overall (most recent timeline entry)
    ///   - each source's *live* sentence (the trailing one being grown by
    ///     the recognizer in the active session)
    /// Earlier session-active sentences are eligible for dropping — they're
    /// stable enough that we don't lose live content by archiving them. If
    /// the recognizer's next snapshot still references them, ingest finds
    /// no matching UUID and silently skips, so the drop sticks.
    private func protectedIDs() -> Set<UUID> {
        var s = Set<UUID>()
        if let id = sentences.last?.id { s.insert(id) }
        if let id = micState.activeIDs.last { s.insert(id) }
        if let id = systemState.activeIDs.last { s.insert(id) }
        return s
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        let protected = protectedIDs()
        // Walk back-to-front so removing doesn't shift indices we still need.
        for i in stride(from: sentences.count - 1, through: 0, by: -1) {
            let s = sentences[i]
            if protected.contains(s.id) { continue }
            if s.lastModified < cutoff { dropSentence(at: i) }
        }
    }

    private func enforceMaxCount() {
        while sentences.count > maxSentenceCount {
            let protected = protectedIDs()
            // Drop the OLDEST non-protected sentence first (insertion order
            // ≈ chronological order).
            if let i = sentences.firstIndex(where: { !protected.contains($0.id) }) {
                dropSentence(at: i)
            } else {
                break  // everything's protected — should be ≤ 3 by definition
            }
        }
    }

    /// Single point that handles "this sentence is going away" — archives
    /// to the transcript file, then removes from the array. Always use this
    /// rather than `sentences.remove(at:)` directly.
    private func dropSentence(at idx: Int) {
        appendToTranscriptFile(sentences[idx])
        sentences.remove(at: idx)
    }

    // MARK: - Transcript archive file

    /// Lazily-built formatters. Reused across writes so we don't pay the
    /// formatter-creation cost on every prune pass.
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let archiveEncoder: JSONEncoder = {
        let e = JSONEncoder()
        // Keep keys in a deterministic order so the file is grep/diff friendly.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// One archived sentence as a single JSON-Lines record. ISO-8601 times
    /// + lowercase source tag make the file easy to load with `jq`, pandas,
    /// or just grep.
    private struct TranscriptRecord: Encodable {
        let time: String
        let source: String          // "mic" | "system"
        let transcription: String
        let translation: String
    }

    private func openTranscriptFile() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.line("Transcript: no Documents directory")
            return
        }
        let dir = docs.appendingPathComponent("transcripts", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.line("Transcript: createDirectory failed: \(error.localizedDescription)")
            return
        }
        let name = Self.filenameFormatter.string(from: Date()) + ".jsonl"
        let url = dir.appendingPathComponent(name)
        // Empty file — JSON Lines has no header, the first record IS the
        // first line. Anything else would break standard JSONL tooling.
        do {
            try Data().write(to: url, options: .atomic)
            transcriptFileURL = url
            Log.line("Transcript: \(url.path)")
        } catch {
            Log.line("Transcript: write failed: \(error.localizedDescription)")
        }
    }

    /// Append one dropped sentence as a JSON Lines record:
    ///
    ///     {"source":"mic","time":"2026-05-16T22:13:07.123Z","transcription":"…","translation":"…"}
    ///
    /// Each invocation writes exactly one line (one JSON object + newline).
    /// Translation may be empty when the source wasn't translated yet or
    /// when translation is disabled — kept as a key for schema stability.
    private func appendToTranscriptFile(_ sentence: Sentence) {
        guard let url = transcriptFileURL else { return }
        let record = TranscriptRecord(
            time: Self.isoFormatter.string(from: sentence.lastModified),
            source: sentence.kind == .microphone ? "mic" : "system",
            transcription: sentence.text,
            translation: sentence.translation
        )
        do {
            var data = try Self.archiveEncoder.encode(record)
            data.append(0x0A)  // newline
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            Log.line("Transcript: append failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Per-source state helpers

    private func activeIDs(for kind: SentenceKind) -> [UUID] {
        kind == .microphone ? micState.activeIDs : systemState.activeIDs
    }
    private func setActiveIDs(_ ids: [UUID], for kind: SentenceKind) {
        if kind == .microphone { micState.activeIDs = ids } else { systemState.activeIDs = ids }
    }
    private func clearActiveIDs(for kind: SentenceKind) {
        setActiveIDs([], for: kind)
    }
}
