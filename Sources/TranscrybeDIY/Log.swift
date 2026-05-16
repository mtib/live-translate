import Foundation

/// Append-only debug log at /tmp/transcrybe.log so we can tail it from a
/// terminal while the app runs. macOS 26 makes the unified log painful to
/// filter for ad-hoc-signed apps.
enum Log {
    private static let url: URL = URL(fileURLWithPath: "/tmp/transcrybe.log")
    private static let queue = DispatchQueue(label: "TranscrybeDIY.log")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func line(_ s: String) {
        let stamped = "\(df.string(from: Date())) \(s)\n"
        queue.async {
            if let data = stamped.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
        print(stamped, terminator: "")
    }
}
