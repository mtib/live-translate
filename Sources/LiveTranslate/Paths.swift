import Foundation

/// All on-disk locations the app writes to live under one root directory:
///
///     ~/Documents/LiveTranslate/
///         transcripts/<YYYY-MM-DD_HH-MM-SS>.jsonl   ← per-run sentence dump
///         recordings/<YYYY-MM-DD_HH-MM-SS>.wav     ← per-run mixed audio
///
/// Both files share the same timestamp filename so the JSONL and the
/// audio for one run are trivially correlatable (just swap extension).
/// Centralised here so changing the layout is one edit.
enum Paths {
    static let runFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Root directory; created on demand.
    static func rootDirectory() throws -> URL {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PathError.noDocumentsDirectory
        }
        let url = docs.appendingPathComponent("LiveTranslate", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `transcripts/` subdir; created on demand.
    static func transcriptsDirectory() throws -> URL {
        let url = try rootDirectory().appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `recordings/` subdir; created on demand.
    static func recordingsDirectory() throws -> URL {
        let url = try rootDirectory().appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `models/` subdir for user-supplied GGML weights. Read-only from
    /// the app's perspective — the user drops files in here themselves
    /// (e.g. a larger whisper model) to override the bundled default.
    /// Not auto-created: if it doesn't exist, no override is in play.
    static var modelsDir: URL {
        // Documents directory may not be reachable yet during early init
        // on a fresh install (e.g. before the run loop has touched it),
        // but the user-override path only matters when transcribe()
        // first runs — by then the dir is guaranteed createable. We
        // intentionally do NOT call createDirectory here so a missing
        // dir is a clean "no override" signal in the file-existence check.
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs
            .appendingPathComponent("LiveTranslate", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// All output paths for a single run, sharing one timestamp stem.
    /// Subtitle paths are computed lazily because they depend on the
    /// language codes the user picked.
    struct Outputs {
        let timestamp: String
        let transcript: URL    // …/transcripts/<stamp>.jsonl
        let recording: URL     // …/recordings/<stamp>.wav
        private let transcriptsDir: URL

        /// SRT path for one language. `langCode` is a 2-letter ISO code
        /// like "de" or "en"; pass the same dir as the transcript so
        /// players can pick subtitles up by suffix matching.
        func subtitle(_ langCode: String) -> URL {
            transcriptsDir.appendingPathComponent("\(timestamp).\(langCode).srt")
        }

        init(timestamp: String, transcript: URL, recording: URL, transcriptsDir: URL) {
            self.timestamp = timestamp
            self.transcript = transcript
            self.recording = recording
            self.transcriptsDir = transcriptsDir
        }
    }
    static func newRunOutputs(now: Date = Date()) throws -> Outputs {
        let stamp = runFilenameFormatter.string(from: now)
        let tDir = try transcriptsDirectory()
        return Outputs(
            timestamp: stamp,
            transcript: tDir.appendingPathComponent("\(stamp).jsonl"),
            recording: try recordingsDirectory().appendingPathComponent("\(stamp).wav"),
            transcriptsDir: tDir
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
