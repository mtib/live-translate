import Foundation
import AVFoundation

/// Microphone capture via `AVAudioEngine`. Always emits 16 kHz mono
/// Float32 so output matches `SystemAudioSource` — required by
/// `MixedAudioSource`, which sample-sums the two streams.
final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private let broadcaster = BufferBroadcaster()
    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    func start() async throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let native = input.outputFormat(forBus: 0)
        sourceFormat = native
        converter = AVAudioConverter(from: native, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: native) { [weak self] buf, _ in
            guard let self, let converted = self.convert(buf) else { return }
            self.broadcaster.emit(converted)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        Log.line("Mic: started, native=\(native), target=\(targetFormat)")
    }

    func stop() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        // Don't `finish()` listeners — Pipeline tears them down via its
        // own task cancellation. Finishing here would race with consumers.
        Log.line("Mic: stopped")
    }

    /// Convert one input-format buffer to the target format. Returns nil
    /// on conversion error; very rare in practice.
    private func convert(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let sourceFormat else { return nil }
        let outCapacity = AVAudioFrameCount(
            Double(src.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
        ) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }
        var didFeed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if didFeed { outStatus.pointee = .noDataNow; return nil }
            didFeed = true
            outStatus.pointee = .haveData
            return src
        }
        return status == .error ? nil : out
    }
}
