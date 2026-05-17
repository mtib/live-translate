import Foundation

/// Recover sessions that didn't finalize cleanly. On app launch we
/// scan `NSTemporaryDirectory()` for `livetranslate-<stamp>/` work
/// directories left over from a previous run (process crashed, force-
/// quit, OS shutdown). For each one we kick off the same MKV +
/// zip + cleanup flow the normal Stop path runs, so the user ends up
/// with the same `<stamp>.zip` in `~/Documents/LiveTranslate/` they
/// would have had if Stop had completed.
///
/// Runs in the background — fire-and-forget from `App.init`. Doesn't
/// block UI; the user can start a new session immediately and the
/// recovery proceeds independently. New sessions use fresh timestamps,
/// so no work-dir collision is possible.
enum CrashRecovery {

    /// Scan for and finalize any leftover work directories. Safe to
    /// call once per app launch.
    static func recoverPendingSessions() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        let workdirs = entries.filter { url in
            url.lastPathComponent.hasPrefix("livetranslate-")
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        guard !workdirs.isEmpty else { return }
        Log.line("CrashRecovery: found \(workdirs.count) leftover work dir(s)")
        for dir in workdirs {
            await finalize(workDir: dir)
        }
    }

    /// Finalize one leftover work directory: build the MKV (if ffmpeg
    /// is available) from whatever's there, then zip + delete.
    /// Idempotent — if a zip already exists at the destination we just
    /// clean up the leftover dir without re-running ffmpeg.
    private static func finalize(workDir: URL) async {
        let name = workDir.lastPathComponent
        let prefix = "livetranslate-"
        guard name.hasPrefix(prefix) else { return }
        let stamp = String(name.dropFirst(prefix.count))
        Log.line("CrashRecovery: finalizing \(stamp)")

        let docsRoot: URL
        do {
            docsRoot = try Paths.documentsRoot()
        } catch {
            Log.line("CrashRecovery: can't reach Documents root, leaving \(stamp) alone: \(error.localizedDescription)")
            return
        }
        let outputs = Paths.Outputs(
            timestamp: stamp,
            workDir: workDir,
            zipDestination: docsRoot.appendingPathComponent("\(stamp).zip")
        )

        // If a zip from a previous successful finalize is already in
        // place, just remove the leftover dir — don't overwrite.
        if FileManager.default.fileExists(atPath: outputs.zipDestination.path) {
            Log.line("CrashRecovery: \(stamp).zip already present; removing leftover work dir")
            try? FileManager.default.removeItem(at: workDir)
            return
        }

        // Languages that the previous run wrote merged-SRT files for.
        // Per-source files (`<stamp>.<source>.<lang>.srt`) have an
        // extra dot in the middle; merged are `<stamp>.<lang>.srt`.
        let langs = discoverLanguages(in: workDir, stamp: stamp)

        await MKVExporter.export(outputs: outputs, langs: langs)
        await ZipArchiver.zipAndCleanup(directory: workDir, into: outputs.zipDestination)
    }

    private static func discoverLanguages(in dir: URL, stamp: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let merged = entries.compactMap { url -> String? in
            let n = url.lastPathComponent
            guard n.hasPrefix("\(stamp).") && n.hasSuffix(".srt") else { return nil }
            let middle = n.dropFirst("\(stamp).".count).dropLast(".srt".count)
            // Per-source files have form `<source>.<lang>` — two parts.
            // Merged files are just `<lang>` — one part, no dot.
            return middle.contains(".") ? nil : String(middle)
        }
        return Array(Set(merged)).sorted()
    }
}
