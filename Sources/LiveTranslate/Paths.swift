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

    /// Compute the two paired output paths for a single run. They share
    /// the same timestamp base name so post-hoc analysis can pair them
    /// just by stem.
    struct Outputs {
        let timestamp: String
        let transcript: URL
        let recording: URL
    }
    static func newRunOutputs(now: Date = Date()) throws -> Outputs {
        let stamp = runFilenameFormatter.string(from: now)
        let t = try transcriptsDirectory().appendingPathComponent("\(stamp).jsonl")
        let r = try recordingsDirectory().appendingPathComponent("\(stamp).wav")
        return Outputs(timestamp: stamp, transcript: t, recording: r)
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
