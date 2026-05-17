import Foundation
import AVFoundation
import Accelerate
import CWhisper

/// Whisper.cpp backend — the project's only `Transcriber` implementation.
///
/// **Model.** Whichever GGML file `build.sh` bundled into the `.app`
/// (see `bundledModelName` below; controlled by `MODEL_NAME` in
/// `tools/build-whisper.sh`). The app has no runtime override — what
/// you built is what you run. MIT-licensed (Whisper weights from
/// OpenAI, GGML repackaging by ggerganov).
///
/// **Pipeline.**
///   1. Audio buffers arrive 48 kHz mono Float32 (post-RNNoise).
///   2. Resample to 16 kHz mono (`WHISPER_SAMPLE_RATE`).
///   3. The accumulator pumps samples while running an RMS-based VAD.
///      A chunk closes on `endChunkAfterSilence` seconds of quiet or at
///      `maxChunkSeconds`, whichever comes first.
///   4. A separate worker task drains chunks off a queue and runs
///      `whisper_full()` serially. Concurrency between (3) and (4) is
///      what stops "second sentence dropped while first is processing".
///   5. Each closed chunk produces **one** `SessionSentence` — joined
///      from whisper's internal segments — stamped with the chunk's
///      audio-stream timing (`startSeconds` / `endSeconds`) so the
///      Pipeline can align it with the paired `.wav`.
///
/// **Hallucination defences.** Whisper trained on captioned video and
/// readily fabricates phrases like "Thanks for watching!" or "[Music]"
/// on silent/short audio. We:
///   - skip whisper entirely when a chunk has no voice;
///   - trim leading/trailing silence (with 100 ms padding) before the
///     call;
///   - pad short trimmed clips with trailing zeros to ≥1.1 s, because
///     whisper's mel-spectrogram threshold silently rejects audio
///     under ~1 s.
///
/// **Continuity.** `initial_prompt` carries the last ~120 chars of the
/// previous chunk's text into the next chunk, so proper nouns and
/// speaker style stay coherent across the (aggressive) silence cuts.
final class WhisperCppTranscriber: Transcriber {

    // MARK: - Tunables

    /// RMS threshold below which a buffer counts as silent. Slightly
    /// higher than Apple's pump because we close chunks more eagerly —
    /// we want to treat quiet background hiss as silence rather than
    /// "voice that holds the chunk open".
    static var silenceRMSThreshold: Float = 0.012

    /// Seconds of continuous silence that close a chunk and trigger a
    /// `whisper_full()` run. Dialled down from 1.6 → 0.7 for snappier
    /// UI updates; the cost is that long thinking-pauses inside a
    /// sentence now end the chunk early. `initial_prompt` carries
    /// context across the boundary so this is rarely visible in output.
    static var endChunkAfterSilence: TimeInterval = 0.7

    /// Skip silence detection for the first chunk-worth of audio. Without
    /// this, an initial half-second of room tone before the user speaks
    /// would close an empty chunk and waste a whisper run.
    static var chunkWarmup: TimeInterval = 0.4

    /// Hard cap on a single chunk's length. If the user just talks
    /// continuously without an audible pause, force a chunk so the UI
    /// gets output instead of waiting forever.
    static var maxChunkSeconds: TimeInterval = 5

    /// Minimum chunk length before we even consider running whisper —
    /// short clips contain too little context and the model often
    /// hallucinates (e.g. "Thanks for watching!" or musical-notation
    /// emoji on near-silent audio).
    static var minChunkSeconds: TimeInterval = 0.6

    /// Maximum number of characters from the previous chunk's tail we
    /// feed back as `initial_prompt` for the next chunk. Whisper's prompt
    /// buffer is bounded (~224 tokens), and too much context can drag
    /// the model toward repetition. One trailing sentence's worth (~120
    /// chars) is enough to keep proper-noun continuity without burning
    /// the budget.
    static var maxInitialPromptChars: Int = 120

    /// Silence padding (in seconds) kept on each side of the voiced span
    /// when trimming a chunk before sending it to whisper. Some padding
    /// is necessary because the RMS detector lags actual speech onset
    /// by a few tens of milliseconds — clipping too tightly chops the
    /// front of the first word. 100 ms is comfortable.
    static var voicePaddingSeconds: TimeInterval = 0.1

    /// Minimum voiced duration in a chunk before we run whisper at all.
    /// Tuned aggressively low (100 ms) so single-syllable utterances
    /// like "Ja" / "yes" — which often register 150–250 ms of voiced
    /// audio after RMS thresholding — make it through. Anything below
    /// is too short to be a meaningful word and risks whisper's
    /// "Thanks for watching!" / "[Music]" hallucinations.
    /// The pad-to-1.1s step in `processChunk` is what makes this safe:
    /// whisper sees a real voiced prefix followed by silence, not
    /// silence on its own.
    static var minVoicedSeconds: TimeInterval = 0.1

    /// Lower bound on the audio length fed to `whisper_full()`. whisper.cpp
    /// silently returns zero segments for audio shorter than ~1 second
    /// (the mel-spectrogram threshold is 100 frames at 10 ms each). When
    /// our trimmed chunk falls below this we pad it with trailing silence;
    /// whisper transcribes the voiced prefix and ignores the rest. **This
    /// is what fixed the "second sentence in a quick triple gets dropped"
    /// bug** — short utterances were being silently swallowed by whisper.
    static var minWhisperInputSeconds: TimeInterval = 1.1

    // MARK: - Whisper context (shared across transcribe() calls)

    /// `whisper_context *` from the C side. Loaded lazily on the first
    /// `transcribe()` call and reused — model load is ~100ms for the
    /// base-q5_1 model, not catastrophic but worth caching.
    private var ctx: OpaquePointer?
    private var modelLoadError: Error?
    /// Serializes `ensureContextLoaded()` so two concurrent
    /// `transcribe()` calls (mic + system) don't both try to
    /// `whisper_init_from_file_with_params` at the same time — that
    /// raced and the second load failed with "failed to load model"
    /// on Metal-backed contexts. After the first call returns, the
    /// stored `ctx` is reused.
    private let ctxLoadLock = NSLock()

    /// Tail of the previous chunk's text per input stream — fed back
    /// to whisper as `initial_prompt` to keep speaker style, proper
    /// nouns, and vocabulary stable across chunk boundaries. Per-source
    /// because mic and system audio have unrelated content; mixing
    /// the tails would pollute each.
    private var previousChunkTail: [SourceTag: String] = [:]

    /// `whisper_full` isn't reentrant on a single context. With two
    /// streams (mic + system) feeding the same `ctx`, we serialize
    /// invocations via this lock. Chunks are typically 1-5 s with
    /// 1-3 s whisper time, so waits are bounded and small.
    private let whisperLock = NSLock()

    /// UI chunk-lifecycle hook — Pipeline installs a closure that
    /// tracks each chunk's state transitions for the in-flight-row
    /// UI. Each chunk gets a UUID generated at voice onset and
    /// referenced consistently through subsequent events. `Sendable`
    /// because accumulator + worker call it from background tasks.
    var onChunkLifecycle: (@Sendable (_ chunkID: UUID, _ source: SourceTag, _ event: ChunkLifecycle) -> Void)?

    /// Lifecycle of one chunk, emitted in order:
    /// `.listening` → `.transcribing` → (`.completed(text)` | `.dropped`).
    /// `.dropped` fires when the chunk was filtered out (no voice,
    /// too short after trim, or whisper produced no segments).
    enum ChunkLifecycle: Sendable {
        case listening
        case transcribing
        case completed(text: String, startSeconds: Double?, endSeconds: Double?)
        case dropped
    }

    /// Cross-talk suppression: the system accumulator stamps the
    /// wall-clock time of the last "system is voiced" buffer here, and
    /// the mic accumulator queries it to decide whether mic samples in
    /// the same time window should be muted (zeroed out) before chunk
    /// emission. Built into the transcriber because it already mediates
    /// shared state for both streams.
    private var lastSystemVoicedAt: Date = .distantPast
    private let crosstalkLock = NSLock()
    /// How long after the last system-voiced buffer we keep treating
    /// the mic as crosstalk-contaminated. Tail covers RNNoise's
    /// envelope follower lag + room reverberation.
    static var crosstalkPersistSeconds: TimeInterval = 0.25

    /// Called by the system accumulator each buffer whose RMS clears
    /// `silenceRMSThreshold`. Cheap (lock + Date()).
    func markSystemVoiced() {
        let now = Date()
        crosstalkLock.withLock { lastSystemVoicedAt = now }
    }

    /// Called by the mic accumulator each buffer. Returns true when
    /// system audio was voiced within the past `crosstalkPersistSeconds`
    /// — the mic accumulator should treat the current buffer as silence
    /// (zero its samples, don't credit voiced span) to suppress speaker
    /// bleed.
    func isSystemRecentlyVoiced() -> Bool {
        let now = Date()
        return crosstalkLock.withLock {
            now.timeIntervalSince(lastSystemVoicedAt) < Self.crosstalkPersistSeconds
        }
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    // MARK: - Model loading

    /// Resolve and load the bundled GGML model file. The build script
    /// downloads + bundles a specific model under the name below; the
    /// app only loads that file (no runtime override) so the user
    /// experience is "what you build is what you run".
    private func ensureContextLoaded() throws -> OpaquePointer {
        ctxLoadLock.lock()
        defer { ctxLoadLock.unlock() }
        if let ctx { return ctx }
        if let modelLoadError { throw modelLoadError }

        let modelURL: URL
        guard let bundleURL = Bundle.main.url(forResource: Self.bundledModelName, withExtension: "bin") else {
            let err = TranscribeError.unavailable("whisper.cpp: bundled model \(Self.bundledModelName).bin missing from app Resources")
            modelLoadError = err
            throw err
        }
        modelURL = bundleURL
        Log.line("Whisper: loading bundled model at \(bundleURL.path)")

        var params = whisper_context_default_params()
        // Metal GPU on Apple Silicon. Pure CPU fallback on Intel — the
        // ggml-metal backend handles this internally.
        params.use_gpu = true
        params.flash_attn = false

        guard let loaded = whisper_init_from_file_with_params(modelURL.path, params) else {
            let err = TranscribeError.unavailable("whisper.cpp: failed to load model at \(modelURL.path)")
            modelLoadError = err
            throw err
        }
        ctx = loaded
        return loaded
    }

    /// Name of the bundled GGML model (without `.bin`). Has to match
    /// the file `build.sh` copies into `Contents/Resources/` and the
    /// `MODEL_NAME` default in `tools/build-whisper.sh`. Large-v3-turbo
    /// is the distilled large variant — large quality, medium-class
    /// speed, the practical sweet spot for live transcription.
    private static let bundledModelName = "ggml-large-v3-turbo-q5_0"

    // MARK: - Transcribe (continuous chunk loop)
    //
    // Data flow, end to end:
    //
    //   AudioSource (buffers @ 48 kHz mono Float32)
    //         │
    //         ▼
    //   [accumulator task]  ── continuously pumps; on silence/max-chunk
    //         │                emits one ChunkBuffer + resets, keeps reading
    //         ▼
    //   chunkQueue (AsyncStream<ChunkBuffer>, unbounded buffer)
    //         │
    //         ▼
    //   [worker task]       ── pulls chunks one at a time; runs whisper_full
    //         │                off-MainActor; yields a SessionSnapshot per chunk
    //         ▼
    //   AsyncThrowingStream<SessionSnapshot, Error>  ← consumed by Pipeline
    //
    // The two tasks must run truly concurrently. The pipeline calls
    // `transcribe()` from MainActor, so we use `Task.detached` to put
    // the whole transcription onto a background executor — otherwise
    // an inherited MainActor would serialize accumulator and worker.

    /// One closed chunk passed from accumulator → worker.
    /// `chunkID` is generated at voice onset and is the same UUID the
    /// accumulator passed to `.listening` / `.transcribing` events;
    /// the worker uses it for `.completed` / `.dropped` so Pipeline
    /// can match events to the same UI entry through the full
    /// lifecycle. `chunkStartSample16k` is the cumulative position of
    /// the chunk's first sample within the audio stream — drives the
    /// sentence's audio-stream-relative timestamps.
    private struct ChunkBuffer {
        let chunkID: UUID
        let index: Int
        let chunkStartSample16k: Int
        let samples16k: [Float]
        let voiceStart: Int?              // nil → pure silence, skip whisper
        let voiceEnd: Int
        let voicedSampleCount: Int
        let closeReason: String           // "silence" | "max-chunk", for logs only
    }

    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale,
        source: SourceTag
    ) -> AsyncThrowingStream<SessionSnapshot, Error> {
        AsyncThrowingStream { continuation in
            // AsyncStream's closure isn't async, so we *must* spawn a
            // Task to drive the run. Inside that task, the rest of the
            // pipeline is structured (async let, await both).
            let runner = Task {
                do {
                    let ctx = try self.ensureContextLoaded()
                    Log.line("Whisper.transcribe[\(source.rawValue)]: starting, locale=\(locale.identifier)")
                    try await self.runChunkLoop(ctx: ctx, audio: audio, locale: locale, source: source, continuation: continuation)
                    Log.line("Whisper.transcribe[\(source.rawValue)]: audio ended, finishing stream")
                    continuation.finish()
                } catch {
                    Log.line("Whisper.transcribe[\(source.rawValue)]: error \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                Log.line("Whisper.transcribe[\(source.rawValue)]: onTermination (\(reason)), cancelling runner")
                runner.cancel()
            }
        }
    }

    /// The two concurrent branches:
    ///
    ///   `accumulate` — read audio forever, emit closed chunks into queue.
    ///   `process`    — drain queue, run whisper, yield snapshots.
    ///
    /// Both run as structured child tasks via `async let`. They share
    /// nothing mutable except `previousChunkTail`, which only the
    /// `process` branch touches.
    private func runChunkLoop(
        ctx: OpaquePointer,
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: SourceLocale,
        source: SourceTag,
        continuation: AsyncThrowingStream<SessionSnapshot, Error>.Continuation
    ) async throws {
        let (chunkQueue, queueSink) = AsyncStream<ChunkBuffer>.makeStream()
        let langCode = String(locale.identifier.prefix(2))
        let tag = source.rawValue

        async let accumulate: Void = {
            await self.accumulateChunks(audio: audio, sink: queueSink, sourceTag: tag, source: source)
            Log.line("accumulator[\(tag)]: audio ended, closing queue")
            queueSink.finish()
        }()

        async let process: Void = {
            Log.line("worker[\(tag)]: started")
            for await chunk in chunkQueue {
                if Task.isCancelled { Log.line("worker[\(tag)]: cancelled"); return }
                Log.line("worker[\(tag)]: received chunk #\(chunk.index) (\(chunk.closeReason)), samples=\(chunk.samples16k.count), voiced=\(chunk.voicedSampleCount)")
                do {
                    if let snapshot = try await self.processChunk(
                        ctx: ctx, chunk: chunk, languageCode: langCode, source: source
                    ) {
                        continuation.yield(snapshot)
                        Log.line("worker[\(tag)]: yielded snapshot for chunk #\(chunk.index), segments=\(snapshot.sentences.count)")
                    }
                } catch {
                    Log.line("worker[\(tag)]: whisper error on chunk #\(chunk.index): \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }
            }
            Log.line("worker[\(tag)]: queue closed, exiting")
        }()

        _ = await (accumulate, process)
    }

    /// Continuously read audio, segment into chunks at silence / max-chunk
    /// boundaries, hand each closed chunk to the worker. Never blocks on
    /// the worker — that's what fixes the "Y dropped while whisper
    /// processes X" bug. Reset state in place; don't exit the for-await.
    private func accumulateChunks(
        audio: AsyncStream<AVAudioPCMBuffer>,
        sink: AsyncStream<ChunkBuffer>.Continuation,
        sourceTag: String,
        source: SourceTag
    ) async {
        var sampleRate: Float = 48_000
        var silenceFramesForBreak = Int(sampleRate * Float(Self.endChunkAfterSilence))
        var warmupFrames = Int(sampleRate * Float(Self.chunkWarmup))
        var maxFrames = Int(sampleRate * Float(Self.maxChunkSeconds))

        // Whisper rejects audio under ~1 s. Hold silence-close open
        // until the chunk *as a whole* is at least that long. Gating
        // on trim length instead was wrong: short utterances kept the
        // trim small forever, silence-close never fired, max-chunk
        // eventually triggered with a tiny voiced count and the worker
        // dropped the chunk. With this gate the chunk grows past 1.1 s,
        // silence-close fires, trim is short but the worker pads it.
        var silenceMinFrames = Int(sampleRate * Float(Self.minWhisperInputSeconds))

        // Per-chunk accumulators — reset on close, never propagated.
        var samples16k: [Float] = []
        samples16k.reserveCapacity(Int(16_000 * Self.maxChunkSeconds))
        var firstVoiceSample16k: Int? = nil
        var lastVoiceSample16k: Int = 0
        var voicedSampleCount16k: Int = 0
        var totalFrames = 0
        var consecutiveSilentFrames = 0
        var hadVoice = false
        var chunkIndex = 0
        var bufferCount = 0
        /// UUID for the chunk currently being accumulated. Nil until
        /// voice onset; set then for the rest of the chunk's lifecycle.
        /// Pipeline matches lifecycle events back to its in-flight row
        /// via this ID.
        var currentChunkID: UUID? = nil

        // Audio-stream sample counter: cumulative 16 kHz samples ever
        // appended, across all chunks. The chunk's start offset is this
        // counter's value at chunk-open; the sentence's audio-stream
        // timestamps are derived from it. This is what makes SRT cues
        // align with WAV positions (the recorder consumes the same
        // audio broadcaster, so sample-count and WAV-position are 1:1).
        var samplesEverEmitted16k = 0
        var chunkStartSample16k = 0

        // One converter for the whole run so its anti-alias filter state
        // stays smooth across chunks (per-chunk converters click at seams).
        let converter = WhisperResampler()

        Log.line("accumulator[\(sourceTag)]: started")
        for await buf in audio {
            if Task.isCancelled {
                Log.line("accumulator[\(sourceTag)]: task cancelled, exiting")
                return
            }
            bufferCount += 1

            let n = Int(buf.frameLength)
            totalFrames += n

            let bufRate = Float(buf.format.sampleRate)
            if bufRate > 0 && bufRate != sampleRate {
                sampleRate = bufRate
                silenceFramesForBreak = Int(sampleRate * Float(Self.endChunkAfterSilence))
                warmupFrames = Int(sampleRate * Float(Self.chunkWarmup))
                maxFrames = Int(sampleRate * Float(Self.maxChunkSeconds))
                silenceMinFrames = Int(sampleRate * Float(Self.minWhisperInputSeconds))
                Log.line("accumulator[\(sourceTag)]: sampleRate=\(sampleRate) Hz from first buffer")
            }

            // Per-buffer RMS — drives the VAD decision below. For the
            // mic stream, the buffer arriving here may already be
            // silenced by `DenoisingAudioSource(mic)`'s upstream
            // crosstalk gate (which zeros the audio when system is
            // recently voiced). That's why we don't need a separate
            // mute branch here anymore — the RMS just falls below the
            // threshold during system playback and the rest of the
            // VAD logic does the right thing.
            guard let data = buf.floatChannelData?[0] else { continue }
            var ms: Float = 0
            vDSP_measqv(data, 1, &ms, vDSP_Length(n))
            let rms = sqrt(ms)

            let bufStart16k = samples16k.count
            if let resampled = converter.convert(buf) {
                samples16k.append(contentsOf: resampled)
            }
            let bufEnd16k = samples16k.count
            samplesEverEmitted16k += (bufEnd16k - bufStart16k)

            // System publishes its voiced state so the mic side's
            // upstream gate (and any future direct consumers) can
            // suppress crosstalk windows.
            if source == .system && rms >= Self.silenceRMSThreshold {
                self.markSystemVoiced()
            }

            if rms >= Self.silenceRMSThreshold {
                hadVoice = true
                consecutiveSilentFrames = 0
                if firstVoiceSample16k == nil {
                    firstVoiceSample16k = bufStart16k
                    let id = UUID()
                    currentChunkID = id
                    Log.line("accumulator[\(sourceTag)]: voice onset in chunk #\(chunkIndex + 1) (id=\(id.uuidString.prefix(8))) at \(String(format: "%.2f", Float(totalFrames) / sampleRate))s (rms=\(String(format: "%.3f", rms)))")
                    self.onChunkLifecycle?(id, source, .listening)
                }
                lastVoiceSample16k = bufEnd16k
                voicedSampleCount16k += (bufEnd16k - bufStart16k)
            } else {
                consecutiveSilentFrames += n
            }

            // Silence-close is gated on TOTAL chunk length so short
            // utterances (e.g. a single "yes") still produce a chunk:
            // we wait until the chunk grows past whisper's ~1 s minimum,
            // *then* close on silence. The trimmed audio may still be
            // under 1 s and the worker pads it. (An earlier version
            // gated on trim length, which never grew for short
            // utterances → max-chunk fired with tiny voice → dropped.)
            let hitMax = totalFrames >= maxFrames
            let silenceClose = hadVoice
                && totalFrames > warmupFrames
                && totalFrames >= silenceMinFrames
                && consecutiveSilentFrames >= silenceFramesForBreak

            if hitMax || silenceClose {
                chunkIndex += 1
                let reason = hitMax ? "max-chunk" : "silence"
                // Voice-onset always precedes a voiced close, so
                // currentChunkID is set for any chunk we'd actually
                // care to transcribe. Max-chunk close without voice
                // (chunk #N was pure silence) doesn't set an ID,
                // doesn't fire .listening, and the worker just
                // shorts it out — no UI row was ever reserved.
                if let id = currentChunkID {
                    self.onChunkLifecycle?(id, source, .transcribing)
                }
                emitChunk(
                    chunkID: currentChunkID ?? UUID(),
                    index: chunkIndex,
                    reason: reason,
                    sourceTag: sourceTag,
                    sink: sink,
                    samples16k: samples16k,
                    chunkStartSample16k: chunkStartSample16k,
                    firstVoiceSample16k: firstVoiceSample16k,
                    lastVoiceSample16k: lastVoiceSample16k,
                    voicedSampleCount16k: voicedSampleCount16k
                )
                samples16k.removeAll(keepingCapacity: true)
                chunkStartSample16k = samplesEverEmitted16k
                firstVoiceSample16k = nil
                lastVoiceSample16k = 0
                voicedSampleCount16k = 0
                totalFrames = 0
                consecutiveSilentFrames = 0
                hadVoice = false
                currentChunkID = nil
            }
        }

        // Audio stream ended (the audio source closed its broadcaster on
        // Pipeline.stop). Flush any in-flight chunk so trailing audio
        // isn't lost — covers "user clicks Stop mid-sentence" exactly.
        // The worker is responsible for filtering / padding to whisper's
        // minimum if the trailing audio is short.
        if firstVoiceSample16k != nil && !samples16k.isEmpty {
            chunkIndex += 1
            if let id = currentChunkID {
                self.onChunkLifecycle?(id, source, .transcribing)
            }
            emitChunk(
                chunkID: currentChunkID ?? UUID(),
                index: chunkIndex,
                reason: "stream-end-flush",
                sourceTag: sourceTag,
                sink: sink,
                samples16k: samples16k,
                chunkStartSample16k: chunkStartSample16k,
                firstVoiceSample16k: firstVoiceSample16k,
                lastVoiceSample16k: lastVoiceSample16k,
                voicedSampleCount16k: voicedSampleCount16k
            )
        }
        Log.line("accumulator[\(sourceTag)]: for-await ended naturally, buffersSeen=\(bufferCount), chunksEmitted=\(chunkIndex)")
    }

    /// Yield one closed chunk to the worker queue + log.
    private func emitChunk(
        chunkID: UUID,
        index: Int,
        reason: String,
        sourceTag: String,
        sink: AsyncStream<ChunkBuffer>.Continuation,
        samples16k: [Float],
        chunkStartSample16k: Int,
        firstVoiceSample16k: Int?,
        lastVoiceSample16k: Int,
        voicedSampleCount16k: Int
    ) {
        let chunkEndSample16k = chunkStartSample16k + samples16k.count
        Log.line("accumulator[\(sourceTag)]: closing chunk #\(index) (id=\(chunkID.uuidString.prefix(8)), \(reason)) — stream=[\(chunkStartSample16k)…\(chunkEndSample16k)] (\(String(format: "%.2f", Double(chunkStartSample16k) / 16_000))s…\(String(format: "%.2f", Double(chunkEndSample16k) / 16_000))s), voiced16k=\(voicedSampleCount16k), hadVoice=\(firstVoiceSample16k != nil)")
        sink.yield(ChunkBuffer(
            chunkID: chunkID,
            index: index,
            chunkStartSample16k: chunkStartSample16k,
            samples16k: samples16k,
            voiceStart: firstVoiceSample16k,
            voiceEnd: lastVoiceSample16k,
            voicedSampleCount: voicedSampleCount16k,
            closeReason: reason
        ))
    }

    /// Voice-trim + skip-empty + run whisper. Returns nil when the chunk
    /// is filtered out (no voice / too short). Emits **one**
    /// `SessionSentence` per chunk, joining whisper's internal segments
    /// into a single line — punctuation-based further splitting is no
    /// longer worthwhile now that the RMS-based VAD already segments
    /// at natural pauses. Updates `previousChunkTail` on success.
    private func processChunk(
        ctx: OpaquePointer,
        chunk: ChunkBuffer,
        languageCode: String,
        source: SourceTag
    ) async throws -> SessionSnapshot? {
        let tag = source.rawValue
        guard let voiceStart = chunk.voiceStart else {
            // Pure-silence chunk (max-chunk fired with no voice). No
            // UI row was reserved at voice-onset so there's nothing to
            // mark dropped here. Just skip whisper.
            Log.line("worker[\(tag)]: chunk #\(chunk.index) had no voice, skipping")
            return nil
        }

        let padding = Int(16_000 * Self.voicePaddingSeconds)
        let trimStart = max(0, voiceStart - padding)
        let trimEnd = min(chunk.samples16k.count, chunk.voiceEnd + padding)
        var trimmed: [Float]
        if trimStart == 0 && trimEnd == chunk.samples16k.count {
            trimmed = chunk.samples16k
        } else {
            trimmed = Array(chunk.samples16k[trimStart..<trimEnd])
        }

        // Only gate on voiced-sample count. Trim length is irrelevant
        // here because `processChunk` pads short clips to 1.1 s before
        // whisper runs — gating on trim length was filtering out chunks
        // like "Ja" where 200-300 ms of voice + 100 ms padding stays
        // well below `minChunkSeconds`.
        let minVoicedSamples = Int(16_000 * Self.minVoicedSeconds)
        if chunk.voicedSampleCount < minVoicedSamples {
            Log.line("worker[\(tag)]: chunk #\(chunk.index) too short (voiced=\(chunk.voicedSampleCount) < \(minVoicedSamples)), skipping")
            self.onChunkLifecycle?(chunk.chunkID, source, .dropped)
            return nil
        }

        // Whisper silently drops audio shorter than ~1 second. Pad short
        // clips with trailing zeros so the model actually runs against
        // the voiced prefix.
        let minWhisperSamples = Int(16_000 * Self.minWhisperInputSeconds)
        let preLen = trimmed.count
        if trimmed.count < minWhisperSamples {
            trimmed.append(contentsOf: repeatElement(0, count: minWhisperSamples - trimmed.count))
            Log.line("worker[\(tag)]: chunk #\(chunk.index) padded \(preLen) → \(trimmed.count) samples (under whisper minimum)")
        }

        let prompt = previousChunkTail[source] ?? ""
        let started = Date()
        Log.line("worker[\(tag)]: chunk #\(chunk.index) → whisper_full (samples=\(trimmed.count), prompt=\"\(prompt.prefix(40))\")")
        let segments = try await self.runWhisperLocked(
            ctx: ctx, samples: trimmed, languageCode: languageCode, initialPrompt: prompt
        )
        let elapsed = Date().timeIntervalSince(started)
        Log.line("worker[\(tag)]: chunk #\(chunk.index) ← whisper_full in \(String(format: "%.2f", elapsed))s, segments=\(segments.count)")

        // Join all of whisper's internal segments into a single line.
        // The RMS-based chunker already split on natural pauses, so
        // splitting again on internal segment boundaries would chop
        // mid-thought. `previousChunkTail` carries the tail forward as
        // `initial_prompt` context for the next chunk.
        let joined = segments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            Log.line("worker[\(tag)]: chunk #\(chunk.index) produced no text, skipping")
            self.onChunkLifecycle?(chunk.chunkID, source, .dropped)
            return nil
        }
        previousChunkTail[source] = String(joined.suffix(Self.maxInitialPromptChars))

        // Audio-stream timing: anchor at the chunk's voice onset and
        // end (chunk-local indices + chunk start offset = absolute
        // 16 kHz sample positions; divide by 16 000 for seconds).
        let startSeconds = Double(chunk.chunkStartSample16k + voiceStart) / 16_000
        let endSeconds = Double(chunk.chunkStartSample16k + chunk.voiceEnd) / 16_000

        self.onChunkLifecycle?(chunk.chunkID, source, .completed(
            text: joined, startSeconds: startSeconds, endSeconds: endSeconds
        ))

        return SessionSnapshot(sentences: [
            SessionSentence(
                text: joined, isFinal: true,
                startSeconds: startSeconds, endSeconds: endSeconds
            )
        ])
    }

    /// Instance-level wrapper that serializes whisper_full calls across
    /// all `transcribe()` invocations on this transcriber via
    /// `whisperLock`. Two streams (mic + system) share one ctx; without
    /// the lock concurrent whisper_full calls would corrupt internal
    /// state.
    private func runWhisperLocked(
        ctx: OpaquePointer,
        samples: [Float],
        languageCode: String,
        initialPrompt: String
    ) async throws -> [String] {
        let lock = self.whisperLock
        return try await Task.detached(priority: .userInitiated) {
            lock.lock()
            defer { lock.unlock() }
            return try Self.runWhisperSync(
                ctx: ctx, samples: samples,
                languageCode: languageCode, initialPrompt: initialPrompt
            )
        }.value
    }

    /// Synchronous whisper_full invocation. Caller is expected to be
    /// off the MainActor (`runWhisperLocked` provides that via its
    /// detached Task) and holding `whisperLock`. Takes 1-3 s wall time.
    private static func runWhisperSync(
        ctx: OpaquePointer,
        samples: [Float],
        languageCode: String,
        initialPrompt: String
    ) throws -> [String] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true   // each chunk is independent
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0.0
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

        // C-string lifetimes: language and initial_prompt must remain
        // alive for the duration of whisper_full(). We nest withCString
        // blocks so both pointers stay valid through the call. Empty
        // prompt → leave the field null (default).
        let result: Int32 = languageCode.withCString { langPtr in
            params.language = langPtr
            let inner: (UnsafePointer<CChar>?) -> Int32 = { promptPtr in
                params.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
            if initialPrompt.isEmpty {
                return inner(nil)
            } else {
                return initialPrompt.withCString { promptPtr in inner(promptPtr) }
            }
        }
        if result != 0 {
            throw TranscribeError.unavailable("whisper_full failed: \(result)")
        }
        let segCount = whisper_full_n_segments(ctx)
        var out: [String] = []
        out.reserveCapacity(Int(segCount))
        for i in 0..<segCount {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                let trimmed = String(cString: cStr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out.append(trimmed)
                }
            }
        }
        return out
    }
}

// MARK: - Errors

enum TranscribeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let msg): return msg
        }
    }
}

// MARK: - 48→16 kHz mono Float32 resampler

/// Reusable AVAudioConverter wrapper for downsampling 48 kHz mono Float32
/// → 16 kHz mono Float32. Holds the converter across buffers so the
/// internal anti-aliasing filter state is preserved (smoother output;
/// per-buffer-constructed converters audibly click at boundaries).
private final class WhisperResampler {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = {
        // Whisper requires 16 kHz mono Float32.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Convert one buffer to 16 kHz mono Float32 samples and return them
    /// as a flat array. Returns nil only if the input format is one we
    /// can't bridge (shouldn't happen given our pipeline guarantees).
    func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        // (Re)build converter if input format changed.
        if converter == nil || sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            sourceFormat = input.format
        }
        guard let converter else { return nil }

        // Estimate output capacity from the rate ratio plus a small fudge
        // factor for the converter's internal delay/filter slop.
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else { return nil }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if let error {
            Log.line("WhisperResampler: convert failed: \(error.localizedDescription)")
            return nil
        }

        let n = Int(outBuf.frameLength)
        guard n > 0, let data = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: n))
    }
}
