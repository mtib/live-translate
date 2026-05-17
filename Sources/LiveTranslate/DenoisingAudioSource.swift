import Foundation
import AVFoundation

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
            for await buf in self.upstream.buffers {
                if Task.isCancelled { break }
                if let out = self.denoise(buf) {
                    self.broadcaster.emit(out)
                }
            }
            // Upstream's broadcaster ended (its `stop()` called
            // `finishAll`). Propagate the close down to our subscribers
            // so the recognition pipeline can drain.
            self.broadcaster.finishAll()
            Log.line("Denoise[\(self.label)]: pump exited")
        }
    }

    func stop() async {
        // Cancel the pump as belt-and-suspenders; upstream.stop()
        // ending the for-await is the primary mechanism, but if
        // someone calls stop() out-of-order we still want to wind down.
        pumpTask?.cancel()
        pumpTask = nil
        await upstream.stop()
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
        // Crosstalk gate (mic only, when system is voiced) — replace
        // the whole buffer with silence. Done AFTER denoising so the
        // RNNoise GRU stays in a sensible state on the next non-muted
        // buffer (feeding it zeros would skew its envelope follower).
        if muteWhen?() == true {
            memset(outData, 0, n * MemoryLayout<Float>.size)
        }
        return out
    }
}
