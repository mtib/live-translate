import Foundation
import AVFoundation

/// Microphone capture via AVAudioEngine, exposed as a broadcasting source.
///
/// **Broadcaster pattern.** Each call to the `buffers` property creates a
/// fresh AsyncStream subscribed to the live tap. The tap callback fans the
/// buffer out to every active subscriber. Without this, the second call to
/// `start()` (or any caller that reads `buffers` after a prior consumer's
/// iterator has finished) silently receives nothing — the recognizer then
/// hits its "no speech detected" timeout and gives up after ~50 ms. That
/// was the cause of the "won't restart after Stop" bug.
final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// Live continuations, keyed by an ID so each subscriber can unregister
    /// itself when its consumer task finishes (via `onTermination`).
    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let listenerQueue = DispatchQueue(label: "MicrophoneSource.listeners")

    /// A fresh hot stream each time. Tap callbacks fan out to all current
    /// subscribers; missing the start of a session is fine because we drop
    /// the listener when its iterator goes away.
    var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { cont in
            let id = UUID()
            self.listenerQueue.sync { self.listeners[id] = cont }
            cont.onTermination = { [weak self] _ in
                self?.listenerQueue.sync { _ = self?.listeners.removeValue(forKey: id) }
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
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            // Snapshot listeners on the queue, yield outside the lock.
            let conts = self.listenerQueue.sync { Array(self.listeners.values) }
            for c in conts { c.yield(buf) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        Log.line("Mic: started, format=\(format)")
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        // Don't `finish()` listeners — Pipeline tears them down via its own
        // task cancellation. Finishing here would race with consumers.
        Log.line("Mic: stopped")
    }
}
