import Foundation
import AVFoundation
import Speech

/// Apple Speech framework backend. One call to `transcribe(...)` runs ONE
/// recognition session — Apple's on-device recognizer caps sessions at
/// roughly 60 seconds, after which it either fires `isFinal = true` or
/// errors with `kAFAssistantErrorDomain` 216. The Pipeline is responsible
/// for restarting sessions to give the user continuous output.
///
/// The transcriber owns the **sentence splitter**: each result emitted by
/// the Apple Speech recognizer carries the full session text, and we parse
/// that into a `SessionSnapshot` before handing it to the Pipeline. This
/// keeps Pipeline backend-agnostic — a future whisper.cpp transcriber can
/// implement its own (probably very different) sentence segmentation.
final class AppleSpeechTranscriber: Transcriber {

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale
    ) -> AsyncThrowingStream<SessionSnapshot, Error> {
        AsyncThrowingStream { continuation in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.identifier)) else {
                continuation.finish(throwing: TranscribeError.noRecognizer(locale.identifier))
                return
            }
            recognizer.supportsOnDeviceRecognition = true
            guard recognizer.isAvailable else {
                continuation.finish(throwing: TranscribeError.unavailable(locale.identifier))
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false  // allow cloud fallback if local model missing
            request.addsPunctuation = true
            Log.line("Transcriber[\(locale.identifier)]: session opened")

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let snapshot = SessionSnapshot(
                        sentences: Self.splitIntoSentences(
                            from: result.bestTranscription,
                            sessionIsFinal: result.isFinal
                        )
                    )
                    continuation.yield(snapshot)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else if result?.isFinal ?? false {
                    continuation.finish()
                }
            }

            // Pump audio into the recognition request from the shared stream.
            let pump = Task {
                for await buf in audio {
                    request.append(buf)
                }
                request.endAudio()
            }

            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel()
                request.endAudio()
            }
        }
    }

    // MARK: - Splitter

    /// Pause threshold for sentence boundaries. Apple's recognizer often
    /// omits a period when the speaker doesn't fully stop, so we *also*
    /// split when the inter-word gap exceeds this. Tunable.
    ///
    /// **Important caveat:** `SFTranscriptionSegment.timestamp` / `.duration`
    /// are **zero on partial results** on current macOS — the gap-based
    /// split therefore only fires when the recognizer emits a final
    /// result (session end or natural finalization). During an ongoing
    /// session, only punctuation-based splits happen; once a session
    /// closes (~60 s on-device, sooner on errors/restarts) Apple emits
    /// a final result with real timestamps and we retroactively split
    /// the text using pauses.
    static var pauseThreshold: TimeInterval = 0.5

    /// Split a recognition result into sentences using two signals:
    ///   1. Sentence-terminating punctuation (`.` `!` `?` `\n`).
    ///   2. **Inter-word silence** longer than `pauseThreshold` — catches
    ///      the dialog case where the recognizer hasn't placed a period
    ///      yet but the speaker clearly paused.
    ///
    /// The trailing fragment (no terminator, no pause after) is the live
    /// partial — it stays mutable until either a terminator lands, a long
    /// pause happens, or the whole session ends (`sessionIsFinal`).
    static func splitIntoSentences(
        from transcription: SFTranscription,
        sessionIsFinal: Bool
    ) -> [SessionSentence] {
        let segments = transcription.segments
        guard !segments.isEmpty else { return [] }

        var sentences: [SessionSentence] = []
        var currentTokens: [String] = []
        var prevEnd: TimeInterval = segments[0].timestamp

        func flush(asFinal: Bool) {
            let text = currentTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sentences.append(SessionSentence(text: text, isFinal: asFinal))
            }
            currentTokens = []
        }

        for (i, seg) in segments.enumerated() {
            // Pause-based split: long silence before this segment ends the
            // previous sentence (even with no terminator).
            if i > 0 {
                let gap = seg.timestamp - prevEnd
                if gap >= Self.pauseThreshold && !currentTokens.isEmpty {
                    Log.line("Splitter: pause gap=\(String(format: "%.2f", gap))s before '\(seg.substring)'")
                    flush(asFinal: true)
                }
            }

            currentTokens.append(seg.substring)
            prevEnd = seg.timestamp + seg.duration

            // Punctuation-based split: if this token ends with a sentence
            // terminator, the sentence ends here.
            if let last = seg.substring.last, "!.?".contains(last) {
                flush(asFinal: true)
            } else if seg.substring.contains("\n") {
                flush(asFinal: true)
            }
        }

        // Whatever's left is the live partial. Mark final only when the
        // whole recognizer session is closing.
        if !currentTokens.isEmpty {
            flush(asFinal: sessionIsFinal)
        }
        return sentences
    }
}

enum TranscribeError: LocalizedError {
    case noRecognizer(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizer(let l): return "No recognizer for \(l)"
        case .unavailable(let l): return "Recognizer not available for \(l) — install the Dictation language in System Settings."
        }
    }
}
