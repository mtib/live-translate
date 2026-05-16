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

/// A snapshot of the active session's sentences in order. The Pipeline
/// reconciles this against its own array by position:
///   - new entries → new `Sentence` with a fresh UUID
///   - existing entries → text/isFinal updated in place (UUID preserved)
///   - missing entries (snapshot shrank) → those `Sentence`s are removed
struct SessionSnapshot: Sendable, Equatable {
    let sentences: [SessionSentence]
}

// MARK: - Sentence (UI-facing data model)

/// One sentence in the rolling transcript. The Pipeline maintains an
/// array of these; the UI renders one row per sentence with the most
/// recent at full opacity and older ones fading out.
struct Sentence: Identifiable, Equatable {
    let id: UUID
    /// Source-language text. Updated in place as the live partial grows.
    var text: String
    /// Target-language text. Empty until the translator handles it.
    var translation: String
    /// What `text` was when we last successfully translated. Used to
    /// detect when a sentence has drifted and needs another translation
    /// pass — so the pipeline doesn't keep ballooning with repeat work.
    var lastTranslatedSource: String
    /// Wall-clock time the source text last changed. Prune uses this to
    /// evict sentences quiet for `maxAgeSeconds`. Translation debounce
    /// uses this to skip partials that are still actively growing.
    var lastModified: Date
    /// True once the backend has emitted a sentence terminator. Final
    /// sentences won't be rewritten; only translation may update.
    var isFinal: Bool
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
