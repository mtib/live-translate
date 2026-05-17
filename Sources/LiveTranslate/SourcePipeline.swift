import Foundation
import AVFoundation

/// Self-contained pipeline for one input stream (mic OR system).
/// Owns its audio source, recorder, and per-source SRT writers; runs
/// recording + recognition until the audio source stops. Final
/// sentence delivery is **not** via this class — `WhisperCppTranscriber`
/// emits chunk lifecycle events directly to `Pipeline`, which builds
/// `Sentence`s and writes the JSONL.
///
/// This class exists so the per-stream side-effects (WAV writes, SRT
/// writes, source-tagged log lines) are encapsulated and out of
/// `Pipeline`'s body.
final class SourcePipeline {
    let source: SourceTag
    let runStartedAt: Date

    private let audioSource: AudioSource
    private let transcriber: Transcriber
    private let locale: SourceLocale
    private let recorder: AudioRecorder?
    private let sourceSubs: SubtitleArchive?
    private let targetSubs: SubtitleArchive?

    init(
        source: SourceTag,
        audioSource: AudioSource,
        transcriber: Transcriber,
        locale: SourceLocale,
        runStartedAt: Date,
        recorder: AudioRecorder?,
        sourceSubs: SubtitleArchive?,
        targetSubs: SubtitleArchive?
    ) {
        self.source = source
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.locale = locale
        self.runStartedAt = runStartedAt
        self.recorder = recorder
        self.sourceSubs = sourceSubs
        self.targetSubs = targetSubs
    }

    /// Run recording + recognition concurrently until the audio source
    /// stops. Both loops consume `audioSource.buffers`; they exit
    /// naturally when the broadcaster closes its continuations (driven
    /// by `audioSource.stop()` on Pipeline.stop()).
    func run() async {
        Log.line("SourcePipeline[\(source.rawValue)]: run started")
        async let rec: Void = runRecordingLoop()
        async let trans: Void = runRecognitionCycle()
        _ = await (rec, trans)
        Log.line("SourcePipeline[\(source.rawValue)]: run finished")
    }

    /// Stop the audio source. Closes the broadcaster, which drains the
    /// loops naturally.
    func stop() async {
        await audioSource.stop()
    }

    /// Block until queued disk writes hit disk. Idempotent.
    func flush() {
        recorder?.flush()
        sourceSubs?.flush()
        targetSubs?.flush()
    }

    /// Append a sentence to this stream's SRT files. Called by
    /// `Pipeline.archiveDrop` when a sentence is being pruned/flushed.
    /// The shared JSONL is handled by the orchestrator.
    func archiveSRT(_ sentence: Sentence) {
        precondition(sentence.source == source,
                     "SourcePipeline[\(source.rawValue)] got a sentence tagged \(sentence.source.rawValue)")
        let start = sentence.createdAt.timeIntervalSince(runStartedAt)
        let end = max(start, sentence.endsAt.timeIntervalSince(runStartedAt))
        sourceSubs?.append(text: sentence.text, startSeconds: start, endSeconds: end)
        if !sentence.translation.isEmpty {
            targetSubs?.append(text: sentence.translation, startSeconds: start, endSeconds: end)
        }
    }

    // MARK: - Loops

    /// Parallel consumer of the audio broadcaster — forwards every PCM
    /// buffer to the recorder. Exits when the broadcaster closes
    /// (`Pipeline.stop` → `audioSource.stop`).
    private func runRecordingLoop() async {
        guard recorder != nil else { return }
        for await buf in audioSource.buffers {
            recorder?.append(buf)
        }
    }

    /// Drive one continuous transcribe() call until the audio stream
    /// ends. The returned `SessionSnapshot`s are not currently used —
    /// Pipeline owns sentence delivery via the transcriber's
    /// per-chunk lifecycle callback. The for-await still has to drain
    /// the stream so the AsyncThrowingStream completes cleanly.
    private func runRecognitionCycle() async {
        let audio = audioSource.buffers
        do {
            for try await _ in transcriber.transcribe(
                audio: audio, locale: locale, source: source
            ) {
                if Task.isCancelled { break }
            }
        } catch is CancellationError {
            // Audio path is graceful-drain-driven; cancellation isn't
            // expected here.
        } catch {
            Log.line("SourcePipeline[\(source.rawValue)]: transcribe error: \(error.localizedDescription)")
        }
    }
}
