import Foundation
import AVFoundation

/// Microphone capture via `AVAudioEngine`, exposed as a broadcasting source.
///
/// **Broadcaster pattern.** Each access to `buffers` returns a fresh
/// `AsyncStream`. The tap callback fans the buffer out to every active
/// subscriber. Without this, a second `transcribe(...)` call after a
/// session ends would attach to an already-drained iterator and silently
/// receive nothing — the recognizer would then hit "no speech detected"
/// within 50 ms.
final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// Live continuations keyed by an ID so each subscriber can unregister
    /// itself when its consumer task finishes. NSLock is fine here — every
    /// access is short and never blocks on IO.
    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let lock = NSLock()

    /// Same heartbeat-style diagnostics as SystemAudioSource so we can
    /// spot silent failures (mic active but no buffers reaching listeners).
    private var diagSamples: Int = 0
    private var diagYielded: Int = 0
    private var diagLastLog: Date = .distantPast

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
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let conts: [AsyncStream<AVAudioPCMBuffer>.Continuation] = self.lock.withLock {
                self.diagSamples += 1
                self.diagYielded += self.listeners.count
                return Array(self.listeners.values)
            }
            for c in conts { c.yield(buf) }
            self.heartbeatIfDue()
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        Log.line("Mic: started, format=\(format)")
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

    /// Once-a-second heartbeat. Mirrors SystemAudioSource — if both are on
    /// you can compare the two streams side-by-side to see who's flowing.
    private func heartbeatIfDue() {
        let now = Date()
        let due: Bool = lock.withLock {
            if now.timeIntervalSince(diagLastLog) < 1.0 { return false }
            diagLastLog = now
            return true
        }
        guard due else { return }
        let listeners = lock.withLock { self.listeners.count }
        Log.line("Mic: heartbeat samples=\(diagSamples) yielded=\(diagYielded) listeners=\(listeners)")
    }
}
