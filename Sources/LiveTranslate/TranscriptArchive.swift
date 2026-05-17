import Foundation

/// Per-run archive file that captures every sentence the Pipeline drops
/// (pruned or evicted by the max-count cap). Paths are owned by `Paths`;
/// this class just writes JSON Lines to whichever URL it's given.
///
/// One JSON object per line:
///
///     {"end":"…","source":"mic","start":"…","transcription":"…","translation":"…"}
///
/// `start` / `end` are ISO-8601 with fractional seconds, anchored to
/// audio-stream positions (see `Sentence.createdAt`/`endsAt`). `source`
/// is one of `"mic"` / `"system"` and identifies which input stream
/// produced the sentence — the paired `.wav` and `.srt` files use the
/// same tag in their filenames. Both `transcription` and `translation`
/// are always present (empty strings allowed). Sorted keys for
/// grep/diff stability.
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
            start: Self.isoFormatter.string(from: sentence.createdAt),
            end: Self.isoFormatter.string(from: sentence.endsAt),
            source: sentence.source.rawValue,
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
        let start: String
        let end: String
        let source: String
        let transcription: String
        let translation: String
    }
}
