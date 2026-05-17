import Foundation
import AVFoundation

/// Self-contained pipeline for one input stream (mic OR system).
/// Owns its audio source, denoiser (via `DenoisingAudioSource`),
/// recorder, and per-source SRT writers. Runs its own recognition
/// loop, emitting completed `Sentence`s as an `AsyncStream` that the
/// main `Pipeline` consumes and merges into the shared UI state.
///
/// **What it does NOT own:** the shared whisper context (provided by
/// the `Transcriber`), the shared JSONL archive (sentences from all
/// sources interleave there), the translator, the translation loop,
/// the prune loop, the sentences UI array. Those are orchestrator
/// concerns — this class is purely the per-stream audio → text → file
/// pipeline.
///
/// **Why two of these instead of one mixer:** previously we summed
/// mic + system into a single stream before transcribing, losing
/// source attribution. With independent denoisers each can adapt to
/// its own noise profile, and per-source files line up exactly with
/// what each microphone heard.
final class SourcePipeline {
    let source: SourceTag
    let runStartedAt: Date

    private let audioSource: AudioSource
    private let transcriber: Transcriber
    private let locale: SourceLocale
    private let recorder: AudioRecorder?
    private let sourceSubs: SubtitleArchive?
    private let targetSubs: SubtitleArchive?

    /// Outgoing sentence stream. One `Sentence` per closed chunk.
    /// Finishes when both the recognition and recording loops exit
    /// (after the audio source's broadcaster closes).
    let sentences: AsyncStream<Sentence>
    private let sentencesContinuation: AsyncStream<Sentence>.Continuation

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

        let (stream, continuation) = AsyncStream<Sentence>.makeStream()
        self.sentences = stream
        self.sentencesContinuation = continuation
    }

    /// Run recognition + recording until the audio source stops. Both
    /// loops consume `audioSource.buffers`; they exit naturally when
    /// the broadcaster closes its continuations (driven by
    /// `audioSource.stop()` on Pipeline.stop()).
    func run() async {
        async let rec: Void = runRecordingLoop()
        async let trans: Void = runRecognitionCycle()
        _ = await (rec, trans)
        sentencesContinuation.finish()
        Log.line("SourcePipeline[\(source.rawValue)]: run finished")
    }

    /// Stop the audio source. Triggers the broadcaster to close, which
    /// drains the loops naturally.
    func stop() async {
        await audioSource.stop()
    }

    /// Block until queued disk writes have hit disk for this stream's
    /// recorder and SRT files. Idempotent.
    func flush() {
        recorder?.flush()
        sourceSubs?.flush()
        targetSubs?.flush()
    }

    /// Append a sentence to the per-source SRT files. Called by the
    /// orchestrator when the sentence is being dropped (pruned or
    /// flushed). The shared JSONL is handled by the orchestrator.
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

    /// Subscribe to the audio source as a parallel consumer of its
    /// broadcaster and forward every PCM buffer to the recorder. Exits
    /// when the broadcaster closes (Pipeline.stop → audioSource.stop).
    private func runRecordingLoop() async {
        guard recorder != nil else { return }
        Log.line("SourcePipeline[\(source.rawValue)]: recording loop started")
        for await buf in audioSource.buffers {
            recorder?.append(buf)
        }
        Log.line("SourcePipeline[\(source.rawValue)]: recording loop exited")
    }

    /// Drive one continuous transcribe() call until the audio stream
    /// ends. Each emitted `SessionSentence` becomes a `Sentence` and
    /// is published to our `sentences` stream.
    private func runRecognitionCycle() async {
        let audio = audioSource.buffers
        do {
            for try await snapshot in transcriber.transcribe(
                audio: audio, locale: locale, source: source
            ) {
                if Task.isCancelled { break }
                ingest(snapshot)
            }
        } catch is CancellationError {
            // Audio path is graceful-drain-driven; cancellation isn't
            // expected here, but bail cleanly if it does arrive.
        } catch {
            Log.line("SourcePipeline[\(source.rawValue)]: transcribe error: \(error.localizedDescription)")
        }
    }

    /// Translate the transcriber's snapshot into `Sentence`s and push
    /// them onto our outgoing stream. The orchestrator owns merging
    /// into the visible array.
    private func ingest(_ snapshot: SessionSnapshot) {
        let now = Date()
        for ss in snapshot.sentences {
            let trimmed = ss.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let startedAt = ss.startSeconds.map { runStartedAt.addingTimeInterval($0) } ?? now
            let endedAt = ss.endSeconds.map { runStartedAt.addingTimeInterval($0) } ?? now
            sentencesContinuation.yield(Sentence(
                id: UUID(),
                text: trimmed,
                translation: "",
                source: source,
                createdAt: startedAt,
                endsAt: max(startedAt, endedAt),
                lastModified: now
            ))
        }
    }
}
