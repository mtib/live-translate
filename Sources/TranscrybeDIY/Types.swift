import Foundation
import AVFoundation

// MARK: - Strongly-typed locale wrappers

/// BCP-47 locale identifier for speech recognition (e.g. "de-DE", "en-US").
struct SourceLocale: Hashable, Identifiable {
    let identifier: String
    var id: String { identifier }
}

/// BCP-47 language code for translation target (e.g. "en", "zh-Hans").
struct TargetLanguage: Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

// MARK: - Transcriber events

/// One sentence as the active recognition session currently sees it. The
/// Transcriber is responsible for parsing the recognizer's growing partial
/// text into discrete sentences — this keeps the Pipeline ignorant of how
/// any particular backend formats its output.
struct SessionSentence: Sendable, Equatable {
    let text: String
    /// True when the source backend has finalized this sentence (sentence
    /// terminator emitted, or the whole session ended).
    let isFinal: Bool
}

/// A snapshot of the active session's sentences in order. The Pipeline
/// reconciles this list against its own `Sentence` array by position:
///   - new entries get new Sentence IDs appended
///   - existing entries get text/isFinal updated in place (stable ID)
///   - missing entries (snapshot is shorter than before) are removed
/// This is what fixes the "an earlier row keeps getting more text" bug —
/// the recognizer occasionally revises away a sentence boundary, and the
/// snapshot pattern lets us drop the orphaned trailing sentence cleanly.
struct SessionSnapshot: Sendable {
    let sentences: [SessionSentence]
}

// MARK: - Sentence (UI-facing data model)

/// Which audio source produced a sentence. Used for UI color-coding so the
/// user can tell at a glance which voice came from where.
enum SentenceKind: String, Sendable, CaseIterable, Identifiable {
    case microphone, systemAudio
    var id: String { rawValue }
}

/// One sentence in the rolling transcript. The Pipeline maintains an array
/// of these (growing as the recognizer emits new sentences, shrinking as
/// the prune pass removes stale ones). The UI renders one row per sentence
/// with the most recent at full opacity and older ones fading out.
struct Sentence: Identifiable, Equatable {
    let id: UUID
    /// Which audio source this came from. Drives color coding in the UI.
    let kind: SentenceKind
    /// Source-language text. Updated in place as the live partial grows.
    var text: String
    /// Target-language text. Empty until the translator has handled it,
    /// then updated whenever the source text changes.
    var translation: String
    /// What `text` was when we last successfully translated. Used to detect
    /// when a sentence has drifted and needs another translation pass —
    /// crucially this means we don't re-send unchanged sentences to the
    /// translator, so the pipeline doesn't keep ballooning with repeat work.
    var lastTranslatedSource: String
    /// Wall-clock time the source text last changed. The prune pass uses
    /// this to evict sentences that have been quiet for `maxAgeSeconds`.
    var lastModified: Date
    /// True once the recognizer has emitted a sentence terminator. Final
    /// sentences won't be rewritten; only their translation may update.
    var isFinal: Bool
}

/// Pipeline status — drives UI state machine. Strings are derived from the
/// case so the View doesn't sprinkle magic strings.
enum PipelineStatus: Equatable {
    case idle
    case requestingPermissions
    case starting
    case listening(sessionIndex: Int, locale: String)
    case reconnecting
    case translating
    case stopped(reason: String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .requestingPermissions: return "Requesting permission…"
        case .starting: return "Starting…"
        case .listening(let i, let loc): return "Listening (\(loc), session #\(i))"
        case .reconnecting: return "Reconnecting…"
        case .translating: return "Translating…"
        case .stopped(let r): return "Stopped: \(r)"
        }
    }
}

// MARK: - Stage protocols

/// Produces raw audio buffers from some source (mic, system audio, file…).
///
/// `start()` is `async` so backends like ScreenCaptureKit (which only
/// exposes async setup) can implement it without faking a synchronous
/// shim. The previous "block on a semaphore" shim deadlocked the main
/// actor — Pipeline already runs in an async context, so this is the
/// natural shape.
protocol AudioSource: AnyObject {
    /// Begin producing buffers. Multiple calls without `stop()` in between
    /// are a programmer error.
    func start() async throws
    /// Stop producing and release resources.
    func stop()
    /// Hot stream of buffers. New subscribers receive future buffers only.
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
}

/// Consumes audio buffers and produces session snapshots — already split
/// into sentences. One call to `transcribe(...)` represents one recognition
/// session; the stream finishes when the session ends. The Pipeline calls
/// this repeatedly to give the user a continuous experience.
protocol Transcriber {
    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale
    ) -> AsyncThrowingStream<SessionSnapshot, Error>
}

/// Translates a single string from source to target language. Implementations
/// may batch or stream internally; we keep the surface as one-shot for simplicity.
protocol Translator {
    func translate(_ text: String, from: SourceLocale, to: TargetLanguage) async throws -> String
}
