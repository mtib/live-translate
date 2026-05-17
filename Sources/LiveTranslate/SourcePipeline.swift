import Foundation
import AVFoundation

/// Per-stream side of the pipeline (one for mic, one for system).
/// Owns the denoised audio source and the per-source WAV recorder;
/// drives recording + transcription until the audio source stops.
/// Sentence delivery is **not** done here — `WhisperCppTranscriber`
/// fires lifecycle events directly to `Pipeline`, which manages the
/// shared UI state and writes the JSONL + merged SRTs.
final class SourcePipeline {
    let source: SourceTag

    private let audioSource: AudioSource
    private let transcriber: Transcriber
    private let locale: SourceLocale
    private let recorder: AudioRecorder?

    init(
        source: SourceTag,
        audioSource: AudioSource,
        transcriber: Transcriber,
        locale: SourceLocale,
        recorder: AudioRecorder?
    ) {
        self.source = source
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.locale = locale
        self.recorder = recorder
    }

    /// Run recording + recognition concurrently until the audio
    /// source stops. Both consume `audioSource.buffers`; they exit
    /// naturally when the broadcaster closes (driven by
    /// `audioSource.stop()` on Pipeline.stop()).
    func run() async {
        Log.line("SourcePipeline[\(source.rawValue)]: run started")
        async let rec: Void = runRecordingLoop()
        async let trans: Void = runRecognitionCycle()
        _ = await (rec, trans)
        Log.line("SourcePipeline[\(source.rawValue)]: run finished")
    }

    /// Stop the audio source. Closes the broadcaster, draining the
    /// loops naturally.
    func stop() async {
        await audioSource.stop()
    }

    /// Block until queued recorder writes hit disk. Idempotent.
    func flush() {
        recorder?.flush()
    }

    // MARK: - Loops

    /// Parallel consumer of the audio broadcaster — forwards each
    /// PCM buffer to the recorder.
    private func runRecordingLoop() async {
        guard recorder != nil else { return }
        for await buf in audioSource.buffers {
            recorder?.append(buf)
        }
    }

    /// Drive one continuous transcribe() call until the audio stream
    /// ends. The returned `SessionSnapshot`s are drained but not
    /// used — `Pipeline` consumes the transcriber's per-chunk
    /// lifecycle callback instead.
    private func runRecognitionCycle() async {
        let audio = audioSource.buffers
        do {
            for try await _ in transcriber.transcribe(
                audio: audio, locale: locale, source: source
            ) {
                if Task.isCancelled { break }
            }
        } catch is CancellationError {
            // graceful-drain path; cancellation not expected
        } catch {
            Log.line("SourcePipeline[\(source.rawValue)]: transcribe error: \(error.localizedDescription)")
        }
    }
}
