import Foundation
import AVFoundation

/// Microphone capture via `AVAudioEngine`, exposed as a broadcasting source.
///
/// Always emits **16 kHz mono Float32** so that:
///   1. Apple Speech sees its documented native format.
///   2. The output is format-compatible with `SystemAudioSource`, which is
///      important when `MixedAudioSource` interleaves them — the recognizer
///      infers format from the first buffer and rejects mismatched ones.
///
/// **Broadcaster pattern.** Each access to `buffers` returns a fresh
/// `AsyncStream`. The tap callback fans the converted buffer out to every
/// active subscriber. Without this, a second `transcribe(...)` call after
/// a session ends would attach to an already-drained iterator and silently
/// receive nothing.
final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// Target format: 16 kHz mono Float32 non-interleaved — what SFSpeech
    /// natively expects, and what `SystemAudioSource` produces.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let lock = NSLock()

    /// Fresh hot stream per access — see broadcaster pattern note above.
    var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.withLock { self.listeners[id] = cont }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

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
            guard let self else { return }
            guard let converted = self.convert(buf) else { return }
            let conts = self.lock.withLock { Array(self.listeners.values) }
            for c in conts { c.yield(converted) }
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
