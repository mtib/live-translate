import Foundation
import AVFoundation
import Speech
import Accelerate

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
            // .dictation tells Apple Speech to expect long-form natural
            // speech (versus .search for short queries / .confirmation
            // for yes-no). Biases the engine toward sentence structure
            // and natural punctuation — closest match for our use case.
            request.taskHint = .dictation
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

            // Pump audio into the recognition request, AND detect long
            // silences so we can end the session early. The latter lets
            // Apple emit a final result with real segment timestamps,
            // which the splitter then uses to break the text on pause
            // boundaries (Apple leaves timestamps at zero on partials,
            // see CLAUDE.md lesson 15a). Net effect: a real-world pause
            // produces a clean sentence break within ~1 s.
            let pump = Task {
                let sampleRate: Float = 16_000
                let silenceFramesForBreak = Int(sampleRate * Float(Self.endSessionAfterSilence))
                let warmupFrames = Int(sampleRate * Float(Self.sessionWarmup))
                var totalFrames = 0
                var consecutiveSilentFrames = 0
                var hadVoice = false

                for await buf in audio {
                    request.append(buf)
                    let n = Int(buf.frameLength)
                    totalFrames += n

                    // RMS of this buffer. AVAudioPCMBuffer is 16 kHz mono
                    // Float32 by the time we get here (both audio sources
                    // normalise to that format).
                    guard let data = buf.floatChannelData?[0] else { continue }
                    var ms: Float = 0
                    vDSP_measqv(data, 1, &ms, vDSP_Length(n))
                    let rms = sqrt(ms)

                    if rms >= Self.silenceRMSThreshold {
                        hadVoice = true
                        consecutiveSilentFrames = 0
                        continue
                    }
                    consecutiveSilentFrames += n

                    // Only break sessions that have actually heard voice
                    // and are past the warmup. Without these guards the
                    // recognizer would be reset every second of dead air.
                    if hadVoice
                        && totalFrames > warmupFrames
                        && consecutiveSilentFrames >= silenceFramesForBreak {
                        Log.line("Transcriber[\(locale.identifier)]: silence \(String(format: "%.1f", Float(consecutiveSilentFrames) / sampleRate))s, ending session at \(String(format: "%.1f", Float(totalFrames) / sampleRate))s")
                        request.endAudio()
                        return  // exit pump; the recognizer will emit a final result
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

    /// Pause threshold (seconds) the splitter uses on a **final** result's
    /// segment timestamps. Partial-result segments have zero timestamps
    /// so this only fires on session end — but we now end sessions
    /// aggressively (see the silence detector below in `transcribe(...)`),
    /// which makes this fire often in practice.
    static var pauseThreshold: TimeInterval = 0.5

    /// RMS threshold below which we consider a buffer "silent" for the
    /// purposes of the in-pump silence detector. Voice usually sits well
    /// above this; background-noise floor sits below. Tunable.
    static var silenceRMSThreshold: Float = 0.01

    /// How much continuous silence (in seconds) inside one recognition
    /// session triggers a forced `endAudio()` — which lets Apple emit
    /// a final result with proper timestamps so the pause-aware splitter
    /// can break the text into multiple sentences. Sized to be longer
    /// than a "thinking pause" so we don't chop mid-thought; speaker
    /// turn-changes typically have more dead air than that.
    static var endSessionAfterSilence: TimeInterval = 1.8

    /// Ignore the silence detector for this long after a session starts —
    /// Apple's recognizer often opens with a brief calibration silence
    /// that we don't want to count as a sentence break.
    static var sessionWarmup: TimeInterval = 1.5

    /// Soft cap on a running sentence's word count. When the splitter has
    /// accumulated this many tokens and then encounters a comma, it
    /// breaks the sentence at the comma instead of letting it grow
    /// unbounded. Catches long run-on monologues where the recognizer
    /// hasn't inserted a period.
    static var maxWordsBeforeCommaBreak: Int = 14

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

            // Hard split: token ends a sentence (period/!/?), or contains a newline.
            if let last = seg.substring.last, "!.?".contains(last) {
                flush(asFinal: true)
                continue
            }
            if seg.substring.contains("\n") {
                flush(asFinal: true)
                continue
            }
            // Soft split: a comma in a sentence that's grown beyond the
            // configured length cap. Stops run-on streams (long monologue,
            // recognizer never inserted a period) from becoming one giant
            // row that spans multiple speaker turns.
            if let last = seg.substring.last,
               last == ",",
               currentTokens.count >= Self.maxWordsBeforeCommaBreak {
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
