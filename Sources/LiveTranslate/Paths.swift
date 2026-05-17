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

    /// All output paths for one in-progress session. Files inside the
    /// work directory are organised into subdirs (`audio/`,
    /// `transcripts/`, `logs/`, `recordings/`) so when the zip is
    /// extracted, VLC opening the MKV doesn't pick up the per-source
    /// SRTs as sidecar tracks (it only scans its own directory).
    struct Outputs {
        /// `<stamp>` — e.g. `2026-05-17_15-42-10`.
        let timestamp: String
        /// Temp directory holding all session artifacts. Removed after
        /// zipping.
        let workDir: URL
        /// Final per-session zip in `~/Documents/LiveTranslate/`.
        let zipDestination: URL

        /// `<workDir>/logs/<stamp>.jsonl` — one JSON object per
        /// emitted sentence, with `source` field.
        var transcript: URL {
            workDir.appendingPathComponent("logs", isDirectory: true)
                   .appendingPathComponent("\(timestamp).jsonl")
        }

        /// `<workDir>/audio/<stamp>.<source>.wav` — per-source
        /// post-denoise + AGC audio.
        func recording(_ source: SourceTag) -> URL {
            workDir.appendingPathComponent("audio", isDirectory: true)
                   .appendingPathComponent("\(timestamp).\(source.rawValue).wav")
        }

        /// `<workDir>/transcripts/<stamp>.<source>.<lang>.srt` —
        /// per-source SRT (kept for debugging / inspection; *not*
        /// embedded in the MKV).
        func subtitle(_ source: SourceTag, _ langCode: String) -> URL {
            workDir.appendingPathComponent("transcripts", isDirectory: true)
                   .appendingPathComponent("\(timestamp).\(source.rawValue).\(langCode).srt")
        }

        /// `<workDir>/transcripts/<stamp>.<lang>.srt` — merged SRT,
        /// `[Mic]` / `[Sys]` prefixed. The MKV embeds this; VLC sees
        /// it as an embedded track, not a sidecar.
        func mergedSubtitle(_ langCode: String) -> URL {
            workDir.appendingPathComponent("transcripts", isDirectory: true)
                   .appendingPathComponent("\(timestamp).\(langCode).srt")
        }

        /// `<workDir>/recordings/<stamp>.mkv` — built by
        /// `MKVExporter`. In its own subdir so it doesn't share a
        /// directory with the SRTs (VLC sidecar auto-load).
        var mkvOutput: URL {
            workDir.appendingPathComponent("recordings", isDirectory: true)
                   .appendingPathComponent("\(timestamp).mkv")
        }

        /// Internal helper — list every per-run subdir that must
        /// exist before writers open their files.
        var allSubdirs: [URL] {
            ["audio", "transcripts", "logs", "recordings"].map {
                workDir.appendingPathComponent($0, isDirectory: true)
            }
        }
    }

    /// Allocate a fresh work directory + per-run subdirs for a new
    /// session.
    static func newRunOutputs(now: Date = Date()) throws -> Outputs {
        let stamp = runFilenameFormatter.string(from: now)
        let workURL = URL(
            fileURLWithPath: NSTemporaryDirectory().appendingPathComponent("livetranslate-\(stamp)", isDirectory: true),
            isDirectory: true
        )
        let fm = FileManager.default
        try fm.createDirectory(at: workURL, withIntermediateDirectories: true)
        let outputs = Outputs(
            timestamp: stamp,
            workDir: workURL,
            zipDestination: try documentsRoot().appendingPathComponent("\(stamp).zip")
        )
        for sub in outputs.allSubdirs {
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        return outputs
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
