import Foundation
import AVFoundation
import Accelerate

/// Combines two `AudioSource`s into one by **summing samples** at mic's
/// pace. The recognizer sees a single stream at real-time speed (1:1
/// audio-time to wall-time ratio), which is what it expects.
///
/// **Why not just interleave?** The previous implementation simply
/// forwarded every upstream buffer to the consumer as it arrived. With
/// both sources running, that means ~2× the buffer rate of a single
/// source — the recognizer received ~2 seconds of "audio time" for every
/// second of real time. Transcription content stayed correct but
/// emission was visibly delayed: SFSpeech's wall-clock-based partial-
/// result heartbeat couldn't keep up with the audio-time it was being
/// fed, so the user saw text appear well after the words were spoken.
///
/// **Mixing algorithm.** Mic is the clock. Each mic buffer drives one
/// output buffer:
///   1. Pull the corresponding number of pending system samples from
///      an internal queue (latest-first within the cap).
///   2. Sample-by-sample sum: `out[i] = mic[i] + system[i]`.
///   3. Pad system with silence if fewer samples are available.
///   4. Emit the summed buffer.
///
/// **Format invariant.** Both inputs MUST be 16 kHz mono Float32
/// non-interleaved. `MicrophoneSource` converts to this on the way in;
/// `SystemAudioSource` produces it natively (via AVAudioConverter).
/// Without matching formats the per-sample sum is nonsensical and the
/// recognizer would reject mismatched buffers anyway.
///
/// **Caveat.** If the mic source never produces buffers (e.g. silent
/// mute device), no output is emitted regardless of system audio. In
/// practice the OS always pushes silence buffers at the mic cadence, so
/// this is a degenerate case we accept.
final class MixedAudioSource: AudioSource {
    private let micSource: AudioSource
    private let systemSource: AudioSource

    /// Queue of pending system samples waiting to be summed with the next
    /// mic buffer. Capped so memory stays bounded if system temporarily
    /// outpaces mic (different OS-side scheduling).
    private var systemQueue: [Float] = []
    private let queueLock = NSLock()
    private let maxQueuedSamples = 16_000   // ~1 second at 16 kHz

    private let broadcaster = BufferBroadcaster()
    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    /// Tasks driving the upstream readers. Cancelled in `stop()`.
    private var micReaderTask: Task<Void, Never>?
    private var systemReaderTask: Task<Void, Never>?

    /// Reusable scratch buffer for the system-samples-padded-to-N array.
    /// Allocated once and grown if a larger mic buffer ever arrives,
    /// avoiding per-call malloc on the hot path.
    private var systemScratch: UnsafeMutablePointer<Float>?
    private var systemScratchCapacity: Int = 0

    deinit {
        systemScratch?.deallocate()
    }

    init(_ mic: AudioSource, _ system: AudioSource) {
        self.micSource = mic
        self.systemSource = system
    }

    func start() async throws {
        try await micSource.start()
        try await systemSource.start()

        let micBuffers = micSource.buffers
        let systemBuffers = systemSource.buffers

        // System reader: fills the queue as fast as buffers arrive.
        systemReaderTask = Task { [weak self] in
            for await buf in systemBuffers {
                self?.appendSystemSamples(buf)
            }
        }

        // Mic reader: drives the output clock. Each mic buffer triggers
        // one mixed-output buffer.
        micReaderTask = Task { [weak self] in
            for await buf in micBuffers {
                self?.emitMixed(forMic: buf)
            }
        }

        Log.line("MixedAudioSource: started")
    }

    func stop() async {
        micReaderTask?.cancel()
        systemReaderTask?.cancel()
        micReaderTask = nil
        systemReaderTask = nil
        await micSource.stop()
        await systemSource.stop()
        queueLock.withLock { systemQueue.removeAll() }
        Log.line("MixedAudioSource: stopped")
    }

    // MARK: - Mixing internals

    /// Extract Float32 samples from a system buffer and append to the queue.
    /// Drops oldest samples if the queue grows past the cap (rare — would
    /// indicate system is outpacing mic, e.g. mic is silent/disconnected).
    private func appendSystemSamples(_ buf: AVAudioPCMBuffer) {
        guard buf.format.channelCount == 1,
              let channelData = buf.floatChannelData?[0]
        else { return }
        let n = Int(buf.frameLength)
        queueLock.withLock {
            systemQueue.append(contentsOf: UnsafeBufferPointer(start: channelData, count: n))
            if systemQueue.count > maxQueuedSamples {
                systemQueue.removeFirst(systemQueue.count - maxQueuedSamples)
            }
        }
    }

    /// Sum a mic buffer with up to its frame-count of pending system
    /// samples, emit the result to all subscribers. The per-sample sum
    /// uses Accelerate's `vDSP_vadd`, which is SIMD-vectorised (NEON on
    /// Apple Silicon, AVX on Intel) — Apple's own AVAudioConverter uses
    /// the same path internally.
    private func emitMixed(forMic micBuf: AVAudioPCMBuffer) {
        guard micBuf.format.channelCount == 1,
              let micData = micBuf.floatChannelData?[0]
        else { return }
        let n = Int(micBuf.frameLength)
        guard n > 0,
              let out = AVAudioPCMBuffer(pcmFormat: micBuf.format, frameCapacity: AVAudioFrameCount(n))
        else { return }
        out.frameLength = AVAudioFrameCount(n)
        guard let outData = out.floatChannelData?[0] else { return }

        // Ensure the scratch buffer can hold n floats; reuse across calls
        // so we don't malloc on every mic tick.
        if systemScratchCapacity < n {
            systemScratch?.deallocate()
            systemScratch = UnsafeMutablePointer<Float>.allocate(capacity: n)
            systemScratchCapacity = n
        }
        let scratch = systemScratch!

        // Zero-fill (so missing-system region acts as silence), then copy
        // the head of the system queue on top.
        memset(scratch, 0, n * MemoryLayout<Float>.size)
        queueLock.withLock {
            let take = min(n, systemQueue.count)
            if take > 0 {
                systemQueue.withUnsafeBufferPointer { src in
                    scratch.update(from: src.baseAddress!, count: take)
                }
                systemQueue.removeFirst(take)
            }
        }

        // outData[i] = micData[i] + scratch[i], SIMD.
        vDSP_vadd(micData, 1, scratch, 1, outData, 1, vDSP_Length(n))

        broadcaster.emit(out)
    }
}
