import Foundation
import AVFoundation

/// Shell out to ffmpeg to build the per-session MKV from the work dir
/// contents (per-source WAVs + already-merged SRTs). No SRT merging
/// here — `MergedSubtitleArchive` maintains those files live during
/// the session, so `ffmpeg` just embeds the existing files.
///
/// 640×360 black background, both WAVs `amix`'d into one audio track,
/// per-language merged SRT embedded with `deu`/`eng`/etc. metadata.
/// First subtitle track is marked default so VLC picks it up
/// automatically.
///
/// No-op (logs a hint) if ffmpeg isn't installed; the rest of the
/// session output (WAVs, SRTs, JSONL) still ends up in the zip.
enum MKVExporter {

    /// Build the MKV at `outputs.mkvOutput`. `langs` is the list of
    /// language codes (e.g. `["de", "en"]`) whose **merged** SRT
    /// files we expect to embed. Per-source SRTs
    /// (`<stamp>.mic.<lang>.srt`, `<stamp>.system.<lang>.srt`) are
    /// deliberately NOT passed to ffmpeg — they're for debugging /
    /// post-hoc inspection only.
    static func export(outputs: Paths.Outputs, langs: [String]) async {
        guard let ffmpeg = locateFFmpeg() else {
            Log.line("MKVExporter: ffmpeg not found (looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin); skipping MKV. Install via `brew install ffmpeg`.")
            return
        }

        let fm = FileManager.default
        let micWAV = outputs.recording(.mic)
        let sysWAV = outputs.recording(.system)
        let haveMic = fm.fileExists(atPath: micWAV.path)
        let haveSys = fm.fileExists(atPath: sysWAV.path)
        guard haveMic || haveSys else {
            Log.line("MKVExporter: no .wav files in work dir; skipping MKV")
            return
        }
        let srtFiles: [(URL, String)] = langs.compactMap { lang in
            let url = outputs.mergedSubtitle(lang)
            return fm.fileExists(atPath: url.path) ? (url, lang) : nil
        }

        // Compute the longest audio duration so we can bound the
        // lavfi video — otherwise `-shortest` would trim the output
        // to the last SRT cue's end time (since subtitle streams
        // count toward "shortest" too).
        let micDur = haveMic ? duration(of: micWAV) : 0
        let sysDur = haveSys ? duration(of: sysWAV) : 0
        let videoDuration = max(micDur, sysDur, 0.5)
        let args = buildArgs(
            micWAV: haveMic ? micWAV : nil,
            sysWAV: haveSys ? sysWAV : nil,
            srts: srtFiles,
            output: outputs.mkvOutput,
            videoDuration: videoDuration
        )
        Log.line("MKVExporter: running ffmpeg (langs=\(srtFiles.map(\.1)))")
        do {
            try await runProcess(executable: ffmpeg, args: args)
            Log.line("MKVExporter: wrote \(outputs.mkvOutput.lastPathComponent)")
        } catch {
            Log.line("MKVExporter: ffmpeg failed: \(error.localizedDescription)")
        }
    }

    // MARK: - ffmpeg argv

    private static func buildArgs(
        micWAV: URL?, sysWAV: URL?, srts: [(URL, String)], output: URL,
        videoDuration: Double
    ) -> [String] {
        // `-t` before `-i` bounds the lavfi color generator to the
        // audio's length. Combined with no `-shortest` further down,
        // the output runs as long as the longest audio input and isn't
        // trimmed to the last subtitle cue.
        var args: [String] = [
            "-y",
            "-loglevel", "warning",
            "-f", "lavfi", "-t", String(format: "%.3f", videoDuration),
            "-i", "color=c=black:s=640x360:r=2",
        ]
        var audioInputs: [Int] = []
        var nextIdx = 1
        if let m = micWAV {
            args.append(contentsOf: ["-i", m.path])
            audioInputs.append(nextIdx)
            nextIdx += 1
        }
        if let s = sysWAV {
            args.append(contentsOf: ["-i", s.path])
            audioInputs.append(nextIdx)
            nextIdx += 1
        }
        let firstSRTIdx = nextIdx
        for (path, _) in srts {
            args.append(contentsOf: ["-i", path.path])
            nextIdx += 1
        }
        if audioInputs.count == 2 {
            args.append(contentsOf: [
                "-filter_complex",
                "[\(audioInputs[0]):a][\(audioInputs[1]):a]amix=inputs=2:normalize=0[aout]"
            ])
        } else if audioInputs.count == 1 {
            args.append(contentsOf: ["-filter_complex", "[\(audioInputs[0]):a]anull[aout]"])
        }
        args.append(contentsOf: ["-map", "0:v"])
        if !audioInputs.isEmpty {
            args.append(contentsOf: ["-map", "[aout]"])
        }
        for i in 0..<srts.count {
            args.append(contentsOf: ["-map", "\(firstSRTIdx + i)"])
        }
        args.append(contentsOf: [
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "stillimage",
            "-c:a", "aac",
            "-c:s", "srt",
        ])
        for (i, (_, lang)) in srts.enumerated() {
            args.append(contentsOf: ["-metadata:s:s:\(i)", "language=\(iso639_3(lang))"])
        }
        if !srts.isEmpty {
            args.append(contentsOf: ["-disposition:s:0", "default"])
        }
        // No `-shortest` — the lavfi `-t` above caps the video, and
        // the audio runs as long as its WAV. Subtitle streams (whose
        // duration is "last cue end") would otherwise force an early
        // cut-off when speech ends before the recording does.
        args.append(output.path)
        return args
    }

    /// AVFoundation-based WAV duration probe. `length / sampleRate` is
    /// exact for PCM and avoids the ffprobe round-trip.
    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : 0
    }

    private static func locateFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ISO 639-1 → 639-3 for the languages the app surfaces. Unknown
    /// codes pass through so the MKV stays valid.
    private static func iso639_3(_ code: String) -> String {
        switch code {
        case "en": return "eng"; case "de": return "deu"
        case "fr": return "fra"; case "es": return "spa"
        case "it": return "ita"; case "pt": return "por"
        case "nl": return "nld"; case "da": return "dan"
        case "sv": return "swe"; case "no": return "nor"
        case "fi": return "fin"; case "pl": return "pol"
        case "cs": return "ces"; case "uk": return "ukr"
        case "ru": return "rus"; case "tr": return "tur"
        case "el": return "ell"; case "he": return "heb"
        case "ar": return "ara"; case "hi": return "hin"
        case "th": return "tha"; case "vi": return "vie"
        case "ja": return "jpn"; case "ko": return "kor"
        case "zh": return "zho"
        default: return code
        }
    }

    /// Run ffmpeg asynchronously; throws on non-zero exit.
    private static func runProcess(executable: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "MKVExporter", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with status \(p.terminationStatus)"]
                    ))
                }
            }
            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}

/// Zip a directory into a single archive and (on success) delete the
/// source directory. Uses macOS-bundled `/usr/bin/zip` so there's no
/// external dependency. Caller is responsible for ensuring the parent
/// directory of `destination` exists.
enum ZipArchiver {
    static func zipAndCleanup(directory: URL, into destination: URL) async {
        do {
            try await run(zipping: directory, into: destination)
            do {
                try FileManager.default.removeItem(at: directory)
                Log.line("ZipArchiver: wrote \(destination.path), cleaned \(directory.path)")
            } catch {
                Log.line("ZipArchiver: zip ok but cleanup failed: \(error.localizedDescription)")
            }
        } catch {
            Log.line("ZipArchiver: zip failed (work dir kept for inspection): \(error.localizedDescription)")
        }
    }

    private static func run(zipping directory: URL, into destination: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            // -r recursive, -q quiet, -X strip extra file attrs.
            // Use directory's basename as the entry inside the zip so
            // extraction produces `<stamp>/...`.
            proc.currentDirectoryURL = directory.deletingLastPathComponent()
            proc.arguments = ["-r", "-q", "-X", destination.path, directory.lastPathComponent]
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "ZipArchiver", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "zip exited with status \(p.terminationStatus)"]
                    ))
                }
            }
            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}
