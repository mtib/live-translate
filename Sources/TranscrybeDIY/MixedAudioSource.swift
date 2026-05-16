import Foundation
import AVFoundation

/// Combines two `AudioSource`s into one by interleaving their buffer
/// streams. The recognizer sees one continuous audio feed and produces
/// transcripts that draw from whichever source has speech at that moment.
///
/// **This is "mixing" in the merge-sense, not the audio-engineering sense.**
/// We forward each upstream buffer as it arrives — there's no sample-level
/// summing. When only one source has speech at any given moment (the common
/// case: you watch a video then occasionally speak), this works well. When
/// both sources speak simultaneously the recognizer hears them back-to-back
/// instead of together, which degrades quality — accepted trade-off given
/// Apple Speech serializes recognizers per-app and won't let two recognition
/// tasks run concurrently.
///
/// **Format invariant.** Both wrapped sources must emit PCM in the same
/// format. `SFSpeechAudioBufferRecognitionRequest.append(_:)` infers format
/// from the first buffer and silently drops mismatched ones. Our
/// `MicrophoneSource` and `SystemAudioSource` both standardize on 16 kHz
/// mono Float32 specifically for this reason.
final class MixedAudioSource: AudioSource {
    private let a: AudioSource
    private let b: AudioSource

    init(_ a: AudioSource, _ b: AudioSource) {
        self.a = a
        self.b = b
    }

    func start() async throws {
        try await a.start()
        try await b.start()
    }

    func stop() async {
        await a.stop()
        await b.stop()
    }

    var buffers: AsyncStream<AVAudioPCMBuffer> {
        let aStream = a.buffers
        let bStream = b.buffers
        return AsyncStream { cont in
            let taskA = Task {
                for await buf in aStream {
                    cont.yield(buf)
                }
            }
            let taskB = Task {
                for await buf in bStream {
                    cont.yield(buf)
                }
            }
            cont.onTermination = { _ in
                taskA.cancel()
                taskB.cancel()
            }
        }
    }
}
