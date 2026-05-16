import Foundation

/// Per-run archive file that captures every sentence the Pipeline drops
/// (pruned or evicted by the max-count cap). Lives at
/// `~/Documents/transcripts/<timestamp>.jsonl` — one JSON object per line:
///
///     {"source":"mic","time":"2026-05-16T22:13:07.123Z","transcription":"…","translation":"…"}
///
/// `time` is ISO-8601 with fractional seconds, `source` is the lowercase
/// archive tag from `SentenceKind`, both `transcription` and `translation`
/// are always present (empty strings allowed). Schema is intentionally
/// stable so consumers (`jq`, pandas, etc.) can load files without surprises.
///
/// One `TranscriptArchive` belongs to one run. The Pipeline creates one on
/// Start and lets it drop on Stop. Writes go through a serial queue so the
/// MainActor (where prune runs) never blocks on disk IO.
final class TranscriptArchive {
    let url: URL
    private let queue = DispatchQueue(label: "TranscriptArchive.write", qos: .utility)

    // Date formatters are expensive to build — cache on the type.
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys for grep/diff stability across runs.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Create a new archive file in `~/Documents/transcripts/`. Throws if
    /// the directory can't be created or the file can't be opened for
    /// writing — both extremely rare on macOS without sandboxing.
    init() throws {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ArchiveError.noDocumentsDirectory
        }
        let dir = docs.appendingPathComponent("transcripts", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Self.filenameFormatter.string(from: Date()) + ".jsonl"
        let url = dir.appendingPathComponent(name)
        // Empty file — JSONL has no header.
        try Data().write(to: url, options: .atomic)
        self.url = url
    }

    /// Append one sentence record. Returns immediately — actual disk IO
    /// happens asynchronously on the archive's queue.
    func append(_ sentence: Sentence) {
        let record = Record(
            time: Self.isoFormatter.string(from: sentence.lastModified),
            source: sentence.kind.archiveTag,
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
        let source: String          // "mic" | "system"
        let transcription: String
        let translation: String
    }
}

enum ArchiveError: LocalizedError {
    case noDocumentsDirectory
    var errorDescription: String? {
        switch self {
        case .noDocumentsDirectory: return "No Documents directory available."
        }
    }
}
