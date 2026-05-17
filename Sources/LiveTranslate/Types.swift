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

/// One sentence as the active recognition session currently sees it. The
/// Transcriber owns sentence splitting — the Pipeline stays ignorant of
/// how any particular backend formats its output.
struct SessionSentence: Sendable, Equatable {
    let text: String
    /// True when the backend has finalized this sentence (terminator
    /// emitted, or whole session ending).
    let isFinal: Bool
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
    /// Wall-clock time the sentence was emitted. Used as the **start
    /// time** when writing SRT subtitle cues, and as the prune cutoff.
    let createdAt: Date
    /// Wall-clock time the sentence was last touched. For the source
    /// text this equals `createdAt` (text doesn't change); the
    /// translation worker pushes it forward when the translation lands,
    /// so the SRT cue **end time** captures "still visible at" rather
    /// than "transcribed at".
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

/// Consumes audio buffers and produces session snapshots. One call to
/// `transcribe(...)` represents one recognition session; the stream
/// finishes when the session ends. The Pipeline calls this repeatedly
/// to give the user continuous output across the backend's session caps.
protocol Transcriber {
    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale
    ) -> AsyncThrowingStream<SessionSnapshot, Error>
}

/// Translates a single string. Implementations carry their own
/// source/target context (Apple's `TranslationSession` does), so the
/// callsite only needs the text.
protocol Translator {
    func translate(_ text: String) async throws -> String
}
