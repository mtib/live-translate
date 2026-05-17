import Foundation
import AVFoundation

/// Streams the live mixed-audio source straight to a `.wav` file on disk.
/// One instance per run, written under `~/Documents/LiveTranslate/recordings/`.
///
/// Stored format is **16 kHz mono signed-16-bit PCM** — same sample rate
/// the recognizer sees, downcast from Float32 to Int16 by `AVAudioFile`
/// on the write path. That makes the output universally playable (QuickTime,
/// VLC, ffmpeg, browsers) at a small bitrate (~32 KB/s).
///
/// Writes are serialized on a private queue so the MainActor — which is
/// where ingest runs — never blocks on disk IO.
final class AudioRecorder {
    let url: URL
    private let file: AVAudioFile
    private let queue = DispatchQueue(label: "AudioRecorder.write", qos: .utility)

    /// Open a file for writing. Throws if the directory isn't writable or
    /// the audio format isn't supported by Core Audio (extremely rare).
    init(at url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
        self.url = url
    }

    /// Append one PCM buffer. Returns immediately; the actual disk write
    /// happens on `queue`. `AVAudioFile.write(from:)` transparently
    /// converts the buffer's Float32 frames to the file's Int16 format.
    func append(_ buffer: AVAudioPCMBuffer) {
        let file = self.file
        queue.async {
            do {
                try file.write(from: buffer)
            } catch {
                Log.line("AudioRecorder: write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Block until every queued write has hit disk. Used on shutdown so
    /// the last few seconds of audio aren't lost when the process exits.
    func flush() {
        queue.sync {}
    }
}
