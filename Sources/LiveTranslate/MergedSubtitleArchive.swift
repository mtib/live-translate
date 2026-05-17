import Foundation

/// Live-updated SRT that merges cues from both input streams for one
/// language. Each `add(...)` call appends a cue (tagged with the
/// source's prefix), re-sorts the in-memory cue list by start time,
/// and rewrites the file from scratch. Cheap for sessions with a few
/// hundred cues (O(N²) total writes, O(N) per cue).
///
/// Writes are serialised on a private dispatch queue so the MainActor
/// (where `Pipeline.graduate` runs) never blocks on disk IO. Use
/// `flush()` to await the queue.
final class MergedSubtitleArchive {
    let url: URL
    private let queue = DispatchQueue(label: "MergedSubtitleArchive.write", qos: .utility)
    private var cues: [Cue] = []

    private struct Cue {
        let start: Double
        let end: Double
        let prefix: String      // "[Mic]" or "[Sys]"
        let text: String
    }

    /// Create (or truncate) the file. Same behaviour as
    /// `SubtitleArchive` — start empty so partial sessions don't
    /// surprise.
    init(at url: URL) throws {
        try Data().write(to: url, options: .atomic)
        self.url = url
    }

    /// Block until queued writes hit disk.
    func flush() {
        queue.sync {}
    }

    /// Append one cue, re-sort by start time, rewrite the file. The
    /// caller passes seconds-from-recording-start; the file is then
    /// directly mountable on the matching `.wav` / `.mkv` timeline.
    func add(text: String, prefix: String, startSeconds: Double, endSeconds: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cue = Cue(
            start: max(0, startSeconds),
            end: max(startSeconds, endSeconds),
            prefix: prefix,
            text: trimmed
        )
        let url = self.url
        queue.async {
            self.cues.append(cue)
            self.cues.sort { $0.start < $1.start }
            var out = ""
            for (i, c) in self.cues.enumerated() {
                out += "\(i + 1)\n\(Self.format(c.start)) --> \(Self.format(c.end))\n\(c.prefix) \(c.text)\n\n"
            }
            do {
                try out.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.line("MergedSubtitleArchive: write failed: \(error.localizedDescription)")
            }
        }
    }

    /// SRT wants `HH:MM:SS,mmm` (comma decimal). Matches the format
    /// `SubtitleArchive` uses so cues line up cleanly across the
    /// per-source and merged files.
    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        var ms = Int(((total - floor(total)) * 1000).rounded())
        if ms == 1000 { ms = 0 }   // rounding rollover
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
