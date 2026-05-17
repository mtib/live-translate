import Foundation

/// Per-run archive file that captures every sentence the Pipeline drops
/// (pruned or evicted by the max-count cap). Paths are owned by `Paths`;
/// this class just writes JSON Lines to whichever URL it's given.
///
/// One JSON object per line:
///
///     {"time":"2026-05-16T22:13:07.123Z","transcription":"…","translation":"…"}
///
/// `time` is ISO-8601 with fractional seconds. Both `transcription` and
/// `translation` are always present (empty strings allowed). Schema is
/// intentionally stable so consumers (`jq`, pandas, etc.) can load
/// without surprises.
///
/// Writes go through a serial queue so the MainActor (where prune runs)
/// never blocks on disk IO.
final class TranscriptArchive {
    let url: URL
    private let queue = DispatchQueue(label: "TranscriptArchive.write", qos: .utility)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // grep/diff-stable keys
        return e
    }()

    /// Create (or truncate) the JSONL file at the given URL.
    init(at url: URL) throws {
        try Data().write(to: url, options: .atomic)   // empty file; JSONL has no header
        self.url = url
    }

    /// Block until every queued write has hit disk. Used on shutdown so
    /// we don't lose in-flight records when the process exits.
    func flush() {
        queue.sync {}
    }

    /// Append one sentence record. Returns immediately; actual disk IO
    /// happens asynchronously on the archive's queue.
    func append(_ sentence: Sentence) {
        let record = Record(
            time: Self.isoFormatter.string(from: sentence.lastModified),
            transcription: sentence.text,
            translation: sentence.translation
        )
        let url = self.url
        queue.async {
            do {
                var data = try Self.encoder.encode(record)
                data.append(0x0A)  // \n
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } catch {
                Log.line("TranscriptArchive: append failed: \(error.localizedDescription)")
            }
        }
    }

    private struct Record: Encodable {
        let time: String
        let transcription: String
        let translation: String
    }
}
