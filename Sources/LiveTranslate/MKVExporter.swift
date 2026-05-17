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
        // the output runs as long as the longest audio input and
        // isn't trimmed to the last subtitle cue.
        // Framerate is `r=10`: low enough to keep file size trivial,
        // high enough that x264 produces a well-formed stream with
        // proper `pix_fmt` / SPS-PPS that VLC will render. The
        // earlier `r=2` plus `-tune stillimage` produced an
        // essentially-empty stream (`pix_fmt=unknown`, junk
        // framerate metadata).
        var args: [String] = [
            "-y",
            "-loglevel", "warning",
            "-f", "lavfi", "-t", String(format: "%.3f", videoDuration),
            "-i", "color=c=black:s=640x360:r=10",
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
            "-c:v", "libx264",
            "-preset", "ultrafast",
            // Drop `-tune stillimage` — combined with very low
            // framerates it was producing a malformed H.264 stream
            // (unknown pix_fmt, junk r_frame_rate metadata) that
            // VLC refused to render.
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-c:s", "srt",
        ])
        for (i, (_, lang)) in srts.enumerated() {
            args.append(contentsOf: ["-metadata:s:s:\(i)", "language=\(iso639_3(lang))"])
        }
        // Explicitly mark video + audio + first subtitle as default.
        // Without this, the MKV mux leaves all dispositions cleared
        // (probably because lavfi-color and amix outputs don't get
        // any default tag), and VLC interprets a video stream with
        // `default=0` as "auto-deselect" — showing the file as
        // audio-only.
        args.append(contentsOf: ["-disposition:v:0", "default"])
        args.append(contentsOf: ["-disposition:a:0", "default"])
        if !srts.isEmpty {
            // `default+forced` — `default` picks the track on open,
            // `forced` makes VLC actually render its cues without
            // the user manually enabling subtitles via the menu.
            args.append(contentsOf: ["-disposition:s:0", "default+forced"])
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

/// Pack a specific set of files into a flat zip (no directory
/// structure) and delete the entire work directory on success. Uses
/// macOS-bundled `/usr/bin/zip` — no external dependency. Caller is
/// responsible for ensuring the parent directory of `destination`
/// exists.
enum ZipArchiver {

    /// Zip exactly `files` into `destination`, flat (no paths), then
    /// delete `workDir`. The work dir holds all the intermediate
    /// per-source artifacts that aren't worth shipping; cleanup is
    /// gated on the zip succeeding so we don't lose data on a
    /// failed pack.
    static func zipFilesAndCleanup(_ files: [URL], into destination: URL, workDir: URL) async {
        // Skip files that aren't actually present (e.g. ffmpeg
        // missing → no MKV). Zip can't include a missing file and
        // we'd rather end up with a partial zip than a hard failure.
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            Log.line("ZipArchiver: no shippable files; leaving work dir for inspection: \(workDir.path)")
            return
        }
        do {
            try await runZip(files: existing, into: destination)
            do {
                try FileManager.default.removeItem(at: workDir)
                Log.line("ZipArchiver: wrote \(destination.path), cleaned \(workDir.path)")
            } catch {
                Log.line("ZipArchiver: zip ok but cleanup failed: \(error.localizedDescription)")
            }
        } catch {
            Log.line("ZipArchiver: zip failed (work dir kept for inspection): \(error.localizedDescription)")
        }
    }

    private static func runZip(files: [URL], into destination: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            // `-j` junks paths so files land flat at the zip root.
            // `-q` quiet, `-X` strip extra file attrs.
            var args: [String] = ["-j", "-q", "-X", destination.path]
            args.append(contentsOf: files.map(\.path))
            proc.arguments = args
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
