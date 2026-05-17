import Foundation

/// All session artifacts live in a per-run **temp work directory**
/// while a session is in progress (audio buffers, JSONL log, per-source
/// SRTs, merged SRTs maintained live). When the session ends and the
/// MKV is built, the directory is zipped into
///
///     ~/Documents/LiveTranslate/<stamp>.zip
///
/// — one self-contained artifact per session — and the work directory
/// is deleted. Restarting a session opens a fresh work directory with
/// a new timestamp.
///
/// Centralising the layout here means changing it is one edit, and the
/// rest of the app uses `Paths.Outputs` accessors rather than building
/// paths inline.
enum Paths {
    static let runFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// `~/Documents/LiveTranslate/` — the only directory the user
    /// sees. Only finished zips land here.
    static func documentsRoot() throws -> URL {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PathError.noDocumentsDirectory
        }
        let url = docs.appendingPathComponent("LiveTranslate", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// All output paths for one in-progress session. Flat layout
    /// inside the work directory — only intermediates that ffmpeg
    /// needs (per-source WAVs, per-language merged SRTs) plus the
    /// two shipped artifacts (JSONL + MKV) live there. Everything
    /// outside `shippedFiles` is deleted when the work dir is
    /// removed after the zip is written.
    struct Outputs {
        /// `<stamp>` — e.g. `2026-05-17_15-42-10`.
        let timestamp: String
        /// Temp directory holding all session artifacts. Removed
        /// after the zip is written.
        let workDir: URL
        /// Final per-session zip in `~/Documents/LiveTranslate/`.
        let zipDestination: URL

        /// `<workDir>/<stamp>.jsonl` — one JSON object per emitted
        /// sentence, with `source` field. The shipped text record.
        var transcript: URL {
            workDir.appendingPathComponent("\(timestamp).jsonl")
        }

        /// `<workDir>/<stamp>.<source>.wav` — per-source post-denoise
        /// + AGC audio. Intermediate only; consumed by ffmpeg's
        /// `amix` filter at session end.
        func recording(_ source: SourceTag) -> URL {
            workDir.appendingPathComponent("\(timestamp).\(source.rawValue).wav")
        }

        /// `<workDir>/<stamp>.<lang>.srt` — live-merged SRT for one
        /// language, both sources interleaved with `[Mic]` / `[Sys]`
        /// prefixes. Intermediate only; embedded in the MKV.
        func mergedSubtitle(_ langCode: String) -> URL {
            workDir.appendingPathComponent("\(timestamp).\(langCode).srt")
        }

        /// `<workDir>/<stamp>.mkv` — final per-session video bundle:
        /// merged audio (amix'd from per-source WAVs) + both
        /// language SRTs embedded over a 640×360 black frame.
        var mkvOutput: URL {
            workDir.appendingPathComponent("\(timestamp).mkv")
        }

        /// The files that go into the user-facing zip: just the
        /// transcript and the MKV. Everything else in the work dir
        /// is intermediate.
        var shippedFiles: [URL] {
            [transcript, mkvOutput]
        }
    }

    /// Allocate a fresh work directory for a new session.
    static func newRunOutputs(now: Date = Date()) throws -> Outputs {
        let stamp = runFilenameFormatter.string(from: now)
        let workURL = URL(
            fileURLWithPath: NSTemporaryDirectory().appendingPathComponent("livetranslate-\(stamp)", isDirectory: true),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        return Outputs(
            timestamp: stamp,
            workDir: workURL,
            zipDestination: try documentsRoot().appendingPathComponent("\(stamp).zip")
        )
    }
}

enum PathError: LocalizedError {
    case noDocumentsDirectory
    var errorDescription: String? {
        switch self {
        case .noDocumentsDirectory: return "No Documents directory available."
        }
    }
}

// Small `String` helper that appendingPathComponent doesn't exist on.
private extension String {
    func appendingPathComponent(_ s: String, isDirectory: Bool = false) -> String {
        let base = hasSuffix("/") ? self : self + "/"
        return base + s + (isDirectory && !s.hasSuffix("/") ? "/" : "")
    }
}
