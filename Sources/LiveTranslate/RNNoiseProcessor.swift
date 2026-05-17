import Foundation
import AVFoundation
import CRNNoise

/// Thin Swift wrapper around RNNoise (xiph, v0.1.1). The C API processes
/// **480-sample frames at 48 kHz mono** and takes/returns Float32 samples
/// scaled to the int16 range (±32768), not the normalised ±1 range we
/// use everywhere else. This wrapper handles:
///
///   - Allocation + lifetime of the `DenoiseState`.
///   - Buffering input across calls so partial frames don't cause skips
///     — the user feeds in whatever-sized buffers, this class emits
///     480-sample frames steadily.
///   - The int16-scale ⇄ unit-scale conversion at the boundary.
///
/// Frame size of 480 at 48 kHz = 10 ms of latency. That's the minimum
/// algorithmic latency for RNNoise.
final class RNNoiseProcessor {

    /// Samples per RNNoise frame at 48 kHz (10 ms). Public so callers
    /// can size their own buffers if they want.
    static let frameSize: Int = 480

    /// Scale factor between our normalised Float32 audio and the int16
    /// representation RNNoise expects. 32768 = 1 << 15.
    private static let int16Scale: Float = 32768.0

    /// Opaque `DenoiseState*` from the C side.
    private var state: OpaquePointer?
    private var inputAccumulator: [Float] = []
    /// Output is delivered in 480-sample chunks; we hold a small ring of
    /// emitted samples so callers can pull arbitrary sizes back out.
    private var outputAccumulator: [Float] = []

    init() {
        // rnnoise_create allocates a DenoiseState; the model is the
        // statically-linked default embedded in rnn_data.c. The Swift
        // bridge surfaces it as OpaquePointer because rnnoise.h only
        // forward-declares the struct.
        state = rnnoise_create(nil)
    }

    deinit {
        if let state {
            rnnoise_destroy(state)
        }
    }

    /// Feed normalised Float32 samples (range ±1) in any quantity. The
    /// processor buffers internally and runs RNNoise on full 480-sample
    /// frames at 48 kHz. Output is appended to the internal queue and
    /// returned via `drain(into:)`.
    func feed(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // Append, scaled to int16 range.
        let oldEnd = inputAccumulator.count
        inputAccumulator.append(contentsOf: repeatElement(0, count: count))
        for i in 0..<count {
            inputAccumulator[oldEnd + i] = samples[i] * Self.int16Scale
        }
        // Process all full frames available.
        while inputAccumulator.count >= Self.frameSize, let state {
            var inFrame = [Float](repeating: 0, count: Self.frameSize)
            var outFrame = [Float](repeating: 0, count: Self.frameSize)
            for i in 0..<Self.frameSize { inFrame[i] = inputAccumulator[i] }
            inputAccumulator.removeFirst(Self.frameSize)
            _ = inFrame.withUnsafeMutableBufferPointer { inP in
                outFrame.withUnsafeMutableBufferPointer { outP in
                    rnnoise_process_frame(state, outP.baseAddress, inP.baseAddress)
                }
            }
            // Scale back to normalised range and queue.
            for i in 0..<Self.frameSize {
                outputAccumulator.append(outFrame[i] / Self.int16Scale)
            }
        }
    }

    /// Pull up to `count` denoised samples into `dst`. Returns how many
    /// were actually written. The remainder of `dst` (if any) is left
    /// untouched; the caller should fill the gap with silence or wait
    /// for more input.
    func drain(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let take = min(count, outputAccumulator.count)
        for i in 0..<take { dst[i] = outputAccumulator[i] }
        outputAccumulator.removeFirst(take)
        return take
    }

    /// Drop any buffered state. Call between recognition sessions if
    /// you want the denoiser to forget recent context.
    func reset() {
        inputAccumulator.removeAll(keepingCapacity: true)
        outputAccumulator.removeAll(keepingCapacity: true)
    }
}
