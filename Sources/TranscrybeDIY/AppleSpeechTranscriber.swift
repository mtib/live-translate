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

            // Per-instance throughput counter so we can spot whichever
            // session is starved when dual-source is on. Logged from the
            // pump task.
            var appendedBuffers = 0
            let bufferCountLock = NSLock()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let snapshot = SessionSnapshot(
                        sentences: Self.splitIntoSentences(
                            result.bestTranscription.formattedString,
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

            // Pump audio into the recognition request from the shared mic stream.
            let pump = Task {
                var lastLog = Date.distantPast
                for await buf in audio {
                    request.append(buf)
                    bufferCountLock.withLock { appendedBuffers += 1 }
                    if Date().timeIntervalSince(lastLog) >= 1.0 {
                        let count = bufferCountLock.withLock { appendedBuffers }
                        Log.line("Transcriber[\(locale.identifier)]: appended=\(count)")
                        lastLog = Date()
                    }
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

    /// Split a recognition result into sentences. A sentence ends at `.` `!`
    /// `?` followed by whitespace/EOS, or at a literal newline. Punctuation
    /// stays with its sentence. The trailing fragment (no terminator yet) is
    /// kept as the last entry — it is the **live partial** that the UI will
    /// keep updating as the user speaks.
    ///
    /// `sessionIsFinal` indicates whether the whole recognizer session is
    /// closing — when true, even the trailing fragment is marked `isFinal`.
    static func splitIntoSentences(_ s: String, sessionIsFinal: Bool) -> [SessionSentence] {
        guard !s.isEmpty else { return [] }
        var finished: [String] = []
        var current = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]
            current.append(ch)
            let nextIsBoundary: Bool = {
                if ch == "\n" { return true }
                if ch == "." || ch == "!" || ch == "?" {
                    if i == chars.count - 1 { return true }
                    let nxt = chars[i + 1]
                    return nxt == " " || nxt == "\n" || nxt == "\t"
                }
                return false
            }()
            if nextIsBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finished.append(trimmed) }
                current = ""
            }
        }
        var out: [SessionSentence] = finished.map { SessionSentence(text: $0, isFinal: true) }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            out.append(SessionSentence(text: tail, isFinal: sessionIsFinal))
        }
        return out
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
