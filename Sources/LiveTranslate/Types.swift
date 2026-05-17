import Foundation
import AVFoundation

// MARK: - Strongly-typed locale wrappers

/// BCP-47 locale identifier for speech recognition (e.g. "de-DE", "en-US").
struct SourceLocale: Hashable, Identifiable, Codable {
    let identifier: String
    var id: String { identifier }

    /// Human-readable label rendered in the current locale. e.g. "de-DE"
    /// becomes "German (Germany)" on an English-speaking Mac. Falls back
    /// to the raw identifier if the system can't localize it.
    var displayName: String {
        let l = Locale.current
        return l.localizedString(forIdentifier: identifier)
            ?? l.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}

/// BCP-47 language code + display name for translation target
/// (e.g. ("en", "English"), ("zh-Hans", "Chinese (Simplified)")).
struct TargetLanguage: Hashable, Identifiable, Codable {
    let code: String
    let name: String
    var id: String { code }
}

// MARK: - Transcriber events

/// Which input stream produced a given sentence. The app captures
/// mic and system audio as independent streams (each with its own
/// RNNoise + accumulator + whisper invocation); this tag flows
/// through to per-stream WAV/SRT files and the JSONL `source` field.
enum SourceTag: String, Codable, Hashable, Sendable, CaseIterable {
    case mic
    case system

    /// Compact label used in merged SRTs and UI annotations.
    var shortLabel: String {
        switch self {
        case .mic: return "Mic"
        case .system: return "Sys"
        }
    }
}

/// One sentence as the active recognition session currently sees it. The
/// Transcriber owns sentence splitting — the Pipeline stays ignorant of
/// how any particular backend formats its output.
///
/// **Audio-stream timing**: when the backend can locate the sentence
/// inside the captured audio, it sets `startSeconds` / `endSeconds`
/// — offsets in seconds from the start of the audio stream the
/// transcriber received. Pipeline anchors those to `runStartedAt` so
/// SRT cue times map directly to positions in the paired `.wav`
/// (both files start at the same audio-stream sample, since the
/// recorder and the transcriber subscribe to the same broadcaster).
/// Backends without per-utterance timing leave them nil; Pipeline
/// then falls back to ingest-time `Date()`.
struct SessionSentence: Sendable, Equatable {
    let text: String
    /// True when the backend has finalized this sentence (terminator
    /// emitted, or whole session ending).
    let isFinal: Bool
    /// Seconds from the start of the audio stream, or nil.
    let startSeconds: Double?
    /// Seconds from the start of the audio stream, or nil.
    let endSeconds: Double?

    init(text: String, isFinal: Bool, startSeconds: Double? = nil, endSeconds: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// A snapshot of sentences emitted by the active transcription chunk.
/// With the whisper.cpp backend each `transcribe()` call yields exactly
/// one snapshot at chunk close, all sentences `isFinal: true`, and then
/// the stream finishes. The Pipeline appends every snapshot sentence
/// to its rolling array — no in-place edits, no retroactive
/// reconciliation. (The dormant Apple Speech backend assumed the
/// opposite shape; if it's ever revived, the Pipeline-side append
/// logic needs to grow snapshot-diffing back.)
struct SessionSnapshot: Sendable, Equatable {
    let sentences: [SessionSentence]
}

// MARK: - Sentence (UI-facing data model)

/// One sentence in the rolling transcript. With chunk-based whisper
/// the source text is immutable once a sentence is emitted — only the
/// `translation` field gets written later, when the translation worker
/// catches up. The Pipeline maintains an array of these; the UI renders
/// one row per sentence with the most recent at full opacity and older
/// ones fading out.
struct Sentence: Identifiable, Equatable {
    let id: UUID
    /// Source-language text. Immutable post-emission.
    let text: String
    /// Target-language text. Empty until the translator handles it.
    var translation: String
    /// Which input stream produced this sentence — drives which
    /// per-source WAV/SRT it lands in and the JSONL `source` field.
    let source: SourceTag
    /// Wall-clock time when the **audio** for this sentence began.
    /// Anchored on `runStartedAt + startSeconds` from the transcriber,
    /// so SRT cue start and JSONL "start" line up with the matching
    /// position in the `.wav` (both sources subscribe to the same audio
    /// broadcaster). Falls back to ingest-time `Date()` for backends
    /// that don't report timing.
    let createdAt: Date
    /// Wall-clock time when the **audio** for this sentence ended.
    /// Used as SRT cue end and JSONL "end". Not changed when the
    /// translation lands (that's a separate field).
    let endsAt: Date
    /// Wall-clock time the sentence was last touched in memory — bumped
    /// when the translation lands. Used by `prune()` so a freshly-
    /// translated row gets a stay of execution. Never written to disk.
    var lastModified: Date
}

/// Pipeline status — drives the UI status line. Kept simple on purpose:
/// the UI doesn't need session indexes or per-source detail.
enum PipelineStatus: Equatable {
    case idle
    case requestingPermissions
    case starting
    case running
    case stopped(reason: String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .requestingPermissions: return "Requesting permission…"
        case .starting: return "Starting…"
        case .running: return "Listening"
        case .stopped(let r): return "Stopped: \(r)"
        }
    }

    /// True when the pipeline is doing something the user-visible status
    /// dot should pulse for. Pure presentation concern, lives here so the
    /// View doesn't have to enumerate cases.
    var isLive: Bool {
        switch self {
        case .running, .starting, .requestingPermissions: return true
        default: return false
        }
    }
}

// MARK: - Stage protocols

/// Produces raw audio buffers from some source (mic, system audio, file…).
///
/// `start()` and `stop()` are both `async` so backends that wrap async
/// APIs (e.g. ScreenCaptureKit) can implement them natively. Pipeline
/// already runs in an async context, so there's nothing awkward about this.
protocol AudioSource: AnyObject {
    /// Begin producing buffers. Multiple calls without `stop()` in
    /// between are a programmer error.
    func start() async throws
    /// Stop producing and release resources. Should be cheap and idempotent.
    func stop() async
    /// Hot stream of buffers. Each access returns a fresh stream — the
    /// source broadcasts each callback to all live subscribers. This is
    /// necessary because AsyncStream is single-consumer; without
    /// broadcasting, restarting recognition silently breaks.
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
}

/// Consumes audio buffers and produces session snapshots for one
/// **input stream** (mic or system). The Pipeline runs one call per
/// active source — calls run concurrently and may share internal state
/// (e.g. the whisper.cpp backend serializes `whisper_full` invocations
/// across calls via a lock).
///
/// The stream finishes when the audio source's `buffers` AsyncStream
/// ends (Pipeline drives this by stopping the audio source on Stop).
protocol Transcriber {
    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale,
        source: SourceTag
    ) -> AsyncThrowingStream<SessionSnapshot, Error>
}

/// Translates a single string. Implementations carry their own
/// source/target context (Apple's `TranslationSession` does), so the
/// callsite only needs the text.
protocol Translator {
    func translate(_ text: String) async throws -> String
}
