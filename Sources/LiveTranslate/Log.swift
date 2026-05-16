import Foundation

/// Append-only debug log at `/tmp/livetranslate.log`. macOS 26 makes the
/// unified log painful to filter for ad-hoc-signed apps, so we just write
/// to disk and `tail -f` it during development.
///
/// **Rotation:** on app launch, if the existing log exceeds `maxBytes`
/// the file is truncated. We don't rotate mid-run — long-running sessions
/// can grow the file but a single run is bounded by sane wall time.
enum Log {
    private static let url: URL = URL(fileURLWithPath: "/tmp/livetranslate.log")
    private static let queue = DispatchQueue(label: "LiveTranslate.log")
    private static let maxBytes: Int = 5 * 1024 * 1024   // 5 MB
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Called once at app launch. If the existing log is over the cap, wipe
    /// it. Cheap — single stat call.
    static func startup() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxBytes {
            try? Data().write(to: url, options: .atomic)
        }
        line("=== Log started ===")
    }

    static func line(_ s: String) {
        let stamped = "\(df.string(from: Date())) \(s)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
