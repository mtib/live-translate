import Foundation
import AVFoundation
import Accelerate

/// Wraps any `AudioSource` and applies `RNNoise` to its 48 kHz mono
/// Float32 buffers before re-broadcasting. Each input stream (mic,
/// system) gets its own instance so denoiser state is independent.
///
/// **Why per-stream denoising?** RNNoise's GRU keeps state across
/// frames — if we summed mic + system first and denoised the mix
/// (the previous design), the network sees a confusing combined
/// signal and the denoiser performs noticeably worse than on each
/// stream separately. With independent denoisers the network can
/// adapt to the room noise vs. ambient computer audio independently.
///
/// Format invariant: upstream MUST emit 48 kHz mono Float32 (RNNoise's
/// native rate). Both `MicrophoneSource` and `SystemAudioSource`
/// already produce that, so wrapping them is a drop-in.
final class DenoisingAudioSource: AudioSource {
    private let upstream: AudioSource
    private let denoiser = RNNoiseProcessor()
    private let broadcaster = BufferBroadcaster()
    private let label: String
    /// Optional crosstalk gate. When set and returns `true`, the
    /// outgoing buffer is replaced with silence before broadcasting —
    /// so every downstream consumer (recorder + transcriber) sees the
    /// same muted audio. Pipeline wires this on the mic instance to
    /// suppress speaker bleed during system playback.
    private let muteWhen: (@Sendable () -> Bool)?

    // MARK: - Auto-gain control
    //
    // Each stream (mic / system) typically arrives at very different
    // loudness levels; the mic depends on speaker distance and gain
    // staging, system audio on the source app's mastering. Without
    // AGC, one stream often dominates the mix and the quieter one
    // gets buried (both in the WAV/MKV mix and in whisper's input).
    //
    // We run a lightweight envelope-follower AGC per instance:
    //   - measure each buffer's RMS via `vDSP_measqv` (SIMD)
    //   - smooth a long-term EMA of RMS over voiced buffers only
    //   - compute a target gain that brings the EMA toward
    //     `agcTargetRMS`, capped between `agcMinGain` and `agcMaxGain`
    //   - smooth the *applied* gain itself (slow ramp) to avoid pumping
    //   - apply via `vDSP_vsmul` (SIMD multiply)
    //
    // The gain is only updated when the input has voiced signal
    // (rms > noise floor); silence preserves the previous gain so the
    // next utterance isn't blasted at max. Both apply paths
    // (recorder + transcriber) see the gained buffer because the
    // multiply happens in the same place the buffer is emitted.
    private static let agcTargetRMS: Float = 0.1
    private static let agcMinGain: Float = 1.0   // never attenuate; only boost
    private static let agcMaxGain: Float = 8.0
    private static let agcNoiseFloor: Float = 0.003  // below this, treat as silence
    private static let agcEnvelopeAlpha: Float = 0.08   // EMA on input RMS
    private static let agcGainSmoothing: Float = 0.06   // EMA on applied gain
    private var agcGain: Float = 1.0
    private var agcRMSAvg: Float = 0.0

    /// Pump task: pulls denoised samples through RNNoise and re-emits.
    /// Lifetime is bounded by the upstream's `buffers` stream — when
    /// upstream is stopped (and its broadcaster's continuations end),
    /// this task's for-await exits naturally.
    private var pumpTask: Task<Void, Never>?

    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    init(_ upstream: AudioSource, label: String, muteWhen: (@Sendable () -> Bool)? = nil) {
        self.upstream = upstream
        self.label = label
        self.muteWhen = muteWhen
    }

    func start() async throws {
        try await upstream.start()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            Log.line("Denoise[\(self.label)]: pump started")
            // Deliberately no `Task.isCancelled` check here — we drain
            // the upstream buffers until its broadcaster signals end.
            // Premature cancellation drops trailing buffers and
            // shortens the recorded WAV / final MKV by a few hundred
            // ms; let `stop()` below drive the natural drain instead.
            for await buf in self.upstream.buffers {
                if let out = self.denoise(buf) {
                    self.broadcaster.emit(out)
                }
            }
            self.broadcaster.finishAll()
            Log.line("Denoise[\(self.label)]: pump exited")
        }
    }

    func stop() async {
        // Stop upstream first — its broadcaster's `finishAll()` makes
        // the pump's `for-await` return cleanly after every queued
        // upstream buffer has been processed. Then await the pump
        // task to be sure those trailing buffers have actually been
        // re-emitted to our broadcaster before subscribers see the
        // closing signal.
        await upstream.stop()
        if let pump = pumpTask {
            pumpTask = nil
            _ = await pump.value
        }
        // Belt-and-suspenders: the pump's exit path already called
        // this, but if start() never ran (e.g. upstream errored),
        // make sure our broadcaster is sealed.
        broadcaster.finishAll()
    }

    /// Apply RNNoise to one 48 kHz mono Float32 buffer. Allocates a
    /// fresh output buffer of the same shape. Returns nil only on
    /// allocation failure (effectively never).
    private func denoise(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.format.channelCount == 1,
              let inData = input.floatChannelData?[0]
        else { return nil }
        let n = Int(input.frameLength)
        guard n > 0,
              let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(n))
        else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        guard let outData = out.floatChannelData?[0] else { return nil }

        denoiser.feed(samples: inData, count: n)
        let drained = denoiser.drain(into: outData, count: n)
        if drained < n {
            // First buffer or two may not have enough denoised samples
            // to fill the output (RNNoise has a 10 ms / 480-sample
            // latency at 48 kHz). Pad with silence rather than emit
            // garbage.
            memset(outData.advanced(by: drained), 0, (n - drained) * MemoryLayout<Float>.size)
        }
        // Auto-gain (SIMD, Accelerate). Adapt to the stream's loudness
        // before the crosstalk gate so the gate-mute is true silence,
        // not muted-but-loud-noise. Updates the running gain only on
        // voiced buffers so silence keeps the previous gain.
        applyAGC(to: outData, count: n)
        // Crosstalk gate (mic only, when system is voiced) — replace
        // the whole buffer with silence. Done AFTER denoising so the
        // RNNoise GRU stays in a sensible state on the next non-muted
        // buffer (feeding it zeros would skew its envelope follower).
        if muteWhen?() == true {
            memset(outData, 0, n * MemoryLayout<Float>.size)
        }
        return out
    }

    /// Envelope-follower AGC. Measures buffer RMS via `vDSP_measqv`,
    /// updates a long-term RMS EMA (only on voiced buffers), targets
    /// `agcTargetRMS`, smooths the gain itself, then applies via
    /// `vDSP_vsmul`. All operations are SIMD-vectorised by Accelerate.
    private func applyAGC(to buffer: UnsafeMutablePointer<Float>, count: Int) {
        // 1. Buffer mean-square → RMS.
        var meanSquare: Float = 0
        vDSP_measqv(buffer, 1, &meanSquare, vDSP_Length(count))
        let bufRMS = sqrt(meanSquare)

        // 2. EMA of input RMS (only when voiced — silence shouldn't
        //    drag the average down and amplify noise on the next word).
        if bufRMS > Self.agcNoiseFloor {
            agcRMSAvg = (1 - Self.agcEnvelopeAlpha) * agcRMSAvg + Self.agcEnvelopeAlpha * bufRMS

            // 3. Target gain brings the EMA toward agcTargetRMS,
            //    clamped to [agcMinGain, agcMaxGain].
            let raw = Self.agcTargetRMS / max(agcRMSAvg, Self.agcNoiseFloor)
            let targetGain = min(max(raw, Self.agcMinGain), Self.agcMaxGain)

            // 4. Smooth the applied gain to avoid pumping.
            agcGain = (1 - Self.agcGainSmoothing) * agcGain + Self.agcGainSmoothing * targetGain
        }

        // 5. Multiply in place: buffer *= agcGain  (SIMD).
        var gain = agcGain
        vDSP_vsmul(buffer, 1, &gain, buffer, 1, vDSP_Length(count))
    }
}
