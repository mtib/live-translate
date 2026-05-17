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

    // MARK: - Per-source AGC (automatic gain control)
    //
    // We track a sliding-window RMS for each input and scale each one
    // toward `agcTargetRMS` before summing. Effect: a quiet mic next to
    // loud system audio is boosted up; a hot mic is pulled down. Without
    // this, whichever source is louder dominates the recognizer's input.
    //
    // The RMS estimate is an exponential moving average updated per
    // buffer — fast enough to follow real-life volume changes (~1 s
    // time constant), slow enough not to "pump" on individual peaks.
    // Gain is clamped to a sensible range so silence isn't amplified
    // into noise and a sudden bang isn't crushed.

    /// Target RMS level (linear Float32, ≈ -26 dBFS — comfortable speech).
    private let agcTargetRMS: Float = 0.05

    /// EMA mix weight per buffer. Slow — about a 1-second time constant
    /// at ~50 buffers/sec — so the gain doesn't chase short loud bursts
    /// or short silences. Keeps pumping inaudible.
    private let agcAlpha: Float = 0.03

    /// Clamp the per-source gain to a *modest* range. Wider clamps
    /// (the first version of this code used ±12 dB) amplified noise
    /// floor far enough to confuse the recognizer. ±6 dB is plenty
    /// to balance two sources whose levels are in the same ballpark
    /// and stops cold any attempt to "lift" silence into hiss.
    private let agcMinGain: Float = 0.5    // -6 dB
    private let agcMaxGain: Float = 2.0    // +6 dB

    /// Below this RMS we don't update the EMA — i.e. background noise
    /// can't drag the running estimate down to the floor and trick the
    /// next loud sample into being amplified. Roughly typical mic
    /// noise-floor + headroom; speech sits well above this.
    private let agcSilenceRMS: Float = 0.005

    /// Running RMS estimate per source. Initialized to the target so the
    /// first few buffers don't get a wild boost.
    private var micRMSEMA: Float
    private var systemRMSEMA: Float

    deinit {
        systemScratch?.deallocate()
    }

    init(_ mic: AudioSource, _ system: AudioSource) {
        self.micSource = mic
        self.systemSource = system
        self.micRMSEMA = agcTargetRMS
        self.systemRMSEMA = agcTargetRMS
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

        // AGC: compute gains for each source from the running RMS estimate.
        var micGain = gainFor(samples: micData, count: n, ema: &micRMSEMA)
        var sysGain = gainFor(samples: scratch, count: n, ema: &systemRMSEMA)

        // outData = micData * micGain
        vDSP_vsmul(micData, 1, &micGain, outData, 1, vDSP_Length(n))
        // outData += scratch * sysGain  (vsma: scaled multiply-add in place)
        vDSP_vsma(scratch, 1, &sysGain, outData, 1, outData, 1, vDSP_Length(n))

        broadcaster.emit(out)
    }

    /// Update the EMA RMS for one source and return the gain that would
    /// pull this buffer toward `agcTargetRMS`. Clamped; silent buffers
    /// pass through at 1.0 so we don't amplify noise floor.
    private func gainFor(
        samples: UnsafePointer<Float>,
        count: Int,
        ema: inout Float
    ) -> Float {
        var ms: Float = 0
        vDSP_measqv(samples, 1, &ms, vDSP_Length(count))
        let rms = sqrt(ms)

        // Update EMA. Skip update on near-silence so a long quiet stretch
        // doesn't drag the EMA down to zero (which would then boost
        // by maxGain when audio comes back).
        if rms > agcSilenceRMS {
            ema = agcAlpha * rms + (1 - agcAlpha) * ema
        }

        // Silence pass-through.
        if ema < agcSilenceRMS { return 1.0 }

        let raw = agcTargetRMS / ema
        return min(agcMaxGain, max(agcMinGain, raw))
    }
}
