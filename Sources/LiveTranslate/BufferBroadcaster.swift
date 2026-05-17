import Foundation
import AVFoundation

/// Fan-out helper for an audio capture source. Owns the set of live
/// `AsyncStream` continuations and lets the source publish one buffer
/// to all current subscribers with a single call.
///
/// Why this exists: `AsyncStream` is single-consumer, so an audio source
/// that wants to support multiple readers must hand each one a *fresh*
/// stream and fan tap callbacks out to every active continuation. All
/// three audio sources (`MicrophoneSource`, `SystemAudioSource`,
/// `MixedAudioSource`) used to duplicate this ~30-line dance — this
/// class centralises it.
///
/// Thread safety: `emit(_:)` is called from audio threads (CoreAudio tap,
/// SCK delegate queue, etc.); `stream` is accessed from MainActor or
/// task contexts. `NSLock` is fine — every critical section is a few
/// instructions and never blocks.
final class BufferBroadcaster {
    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let lock = NSLock()

    /// One fresh `AsyncStream` per access. The continuation auto-removes
    /// itself when its consumer task terminates.
    var stream: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.withLock { self.listeners[id] = cont }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

    /// Number of currently-subscribed consumers. Useful for diagnostics.
    var listenerCount: Int {
        lock.withLock { listeners.count }
    }

    /// Yield a buffer to every current subscriber. Snapshot the
    /// continuations under the lock, yield outside it.
    func emit(_ buffer: AVAudioPCMBuffer) {
        let conts = lock.withLock { Array(listeners.values) }
        for c in conts { c.yield(buffer) }
    }

    /// Close every active subscription so consumers' `for await` loops
    /// exit naturally. Called by audio sources on stop — this is what
    /// lets the Pipeline drain trailing audio rather than aborting
    /// mid-flight via task cancellation.
    func finishAll() {
        let conts = lock.withLock { () -> [AsyncStream<AVAudioPCMBuffer>.Continuation] in
            let cs = Array(listeners.values)
            listeners.removeAll()
            return cs
        }
        for c in conts { c.finish() }
    }
}
