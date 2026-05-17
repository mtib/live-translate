import Foundation

/// Per-run SubRip (`.srt`) subtitle file. Format chosen because:
///   - it's the universal subtitle standard — any video player (VLC,
///     QuickTime, mpv, ffmpeg, browsers) reads it natively, so the
///     `.srt` files pair directly with the run's `.wav` for playback;
///   - it's plain text — you can cat / grep / `less` it just as
///     readably as a custom one-line-per-sentence format.
///
/// Layout per cue:
///
///     1
///     00:00:01,250 --> 00:00:03,500
///     Hallo welt, wie geht es dir?
///
/// Times are seconds offset from the start of the run (and the start
/// of the paired recording). Apple Speech's recognition latency means
/// cues are a few hundred milliseconds behind the audio, but the
/// **same** latency is in the `.wav` itself, so they line up.
///
/// Writes go through a serial queue so the MainActor never blocks on
/// disk IO.
final class SubtitleArchive {
    let url: URL
    private let queue = DispatchQueue(label: "SubtitleArchive.write", qos: .utility)
    private var counter: Int = 0

    init(at url: URL) throws {
        try Data().write(to: url, options: .atomic)   // truncate / create
        self.url = url
    }

    /// Block until queued writes have hit disk. Used on shutdown.
    func flush() {
        queue.sync {}
    }

    /// Append one cue. `startSeconds` and `endSeconds` are offsets from
    /// the start of the recording. `text` may contain newlines — SRT
    /// handles multi-line cues natively. Nothing happens if `text` is
    /// empty (we don't want blank cues).
    func append(text: String, startSeconds: TimeInterval, endSeconds: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let start = Self.format(max(0, startSeconds))
        let end = Self.format(max(startSeconds, endSeconds))
        let url = self.url
        queue.async {
            self.counter += 1
            let block = "\(self.counter)\n\(start) --> \(end)\n\(trimmed)\n\n"
            guard let data = block.data(using: .utf8) else { return }
            do {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } catch {
                Log.line("SubtitleArchive: append failed: \(error.localizedDescription)")
            }
        }
    }

    /// SRT wants `HH:MM:SS,mmm` with a comma decimal separator.
    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
