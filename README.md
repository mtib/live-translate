# LiveTranslate

Floating, translucent macOS 26+ app that captures your **microphone and
system audio** in parallel, transcribes both on-device via
[whisper.cpp](https://github.com/ggerganov/whisper.cpp), and translates
the result with Apple's `Translation` framework. Each session lands
as a single zip in `~/Documents/LiveTranslate/<stamp>.zip` containing
both `.wav`s, the per-source + merged SRTs, the JSONL log, and a
ready-to-watch `.mkv` (640×360 black background, both subtitle tracks
embedded).

When a Premium TTS voice is installed for the target language, the app
also **streams synthesized translations over the LAN**. Open
`http://<mac-ip>:8765/` in a browser to get a dark-mode listen page
with a Listen button, real-time audio, and a live transcript fed over
SSE — no app needed on the phone.

![Default layout](docs/default.png)
![Compact layout](docs/compact.png)

Example session output: [youtu.be/jXrzOEh-zZU](https://www.youtube.com/watch?v=jXrzOEh-zZU)
— the `.mkv` shipped in the zip, uploaded to YouTube with the
extracted SRTs re-attached as caption tracks (YouTube ignores
subtitles embedded inside the container).

## Requirements

- **macOS 26 (Tahoe)** — uses `Translation` framework, `AVSpeechSynthesizer.write(_:toBufferCallback:)`, and `ScreenCaptureKit`. The app will not build or run on earlier releases.
- **Apple Silicon** recommended — whisper.cpp uses the Metal GPU backend; Intel falls back to CPU and is significantly slower.

## Build & run

```sh
brew install cmake ffmpeg     # one-time
./dev-setup.sh                # pre-download GGML models into models/  (optional but recommended)
./build.sh                    # ~60–90 s the first time, ~5 s after
open build/LiveTranslate.app
```

The build clones `whisper.cpp` v1.7.4 into `external/`, compiles it
to static archives, picks the GGML model from `models/` (or downloads
into `build/whisper-models/`), and bundles it into the `.app`. Default
bundled model is `ggml-large-v3-turbo-q5_0` (~570 MB) — distilled
large-v3 with 4 decoder layers, large-class quality at ~3× realtime on
Apple Silicon. Set `WHISPER_MODEL=…` before `./build.sh` and update
`WhisperCppTranscriber.bundledModelName` to match if you want a
different one.

## One-time macOS setup

- **Translation language pack.** Apple downloads pairs on demand —
  add yours under **System Settings → Apple Intelligence & Siri →
  Translation Languages** before first run, otherwise the translation
  panel stays empty.
- **Permissions** (Microphone + Screen Recording). Prompted on first
  launch via `open build/LiveTranslate.app`. Never run the binary
  directly — TCC associates grants with the bundle.
- **Premium TTS voice for the live audio stream.** When a TTS voice
  for your target language is installed, the app starts a local HTTP
  audio stream that speaks each translation out loud. The default
  macOS voices are robotic; **install a Premium voice once** under
  **System Settings → Accessibility → Spoken Content → System Voice →
  your target language → pick a Premium voice → wait for the download**
  (~300–500 MB per language, one-time). "Siri Voice 1" is a good pick
  for English. If no voice is installed for the selected target, the
  stream icon stays hidden — the feature is silently skipped, no
  fallback to a wrong-language voice.
- **Persistent permissions across rebuilds.** Ad-hoc signing churns
  the `cdhash` every build and macOS re-prompts. Create a self-signed
  cert in Keychain Access → Certificate Assistant (name e.g.
  `LiveTranslateDev`, Code Signing, Self Signed Root), then
  `export LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev` — `build.sh`
  picks it up and all future rebuilds reuse the same TCC grants.

## Live translated-audio stream

When running with a source language different from the target and a
Premium TTS voice installed, a radio-waves icon (⋰) appears in the
toolbar. Click it to see:

- The stream URL (`http://<lan-ip>:8765/`) — click to copy
- A QR code to scan with a phone on the same Wi-Fi

Opening the URL in a browser shows a dark-mode listen page. Hit **Listen**
and the page plays the audio live, auto-resyncing when it falls behind.
A scrolling transcript shows each translation alongside the original text
and timestamp, fed by a server-sent events stream at `/events`.

The icon turns **green** while a listener is connected to the audio stream
so you get instant visual feedback that the phone picked up the feed.
Synthesis is also gated on the listener count — if nobody is connected,
the speaker stays silent and skips synthesis entirely.

For players that prefer a direct stream, `/live.wav` is a plain HTTP WAV —
open it in VLC, mpv, or iOS Safari. Chrome works. QuickTime buffers heavily
(30+ s), so avoid it.

To adjust TTS speed: edit `TTSSpeaker.speechRate` in
[`Sources/LiveTranslate/TTSSpeaker.swift`](Sources/LiveTranslate/TTSSpeaker.swift)
— `1.0` is the system default (~175 wpm), `1.05` is the current setting.

## How it works

**Audio capture:** Mic via `AVAudioEngine`, system audio via
`ScreenCaptureKit`. Each stream runs through its own `RNNoise` instance
(on-device denoising, recorded to WAV after this stage) and an
envelope-follower AGC (SIMD via Accelerate's `vDSP`).

**Transcription:** Both streams share one `WhisperCppTranscriber` (shared
`ctx`, `NSLock` around `whisper_full` so the two streams take turns).
Whisper is fed 1–5 s chunks closed on silence; each closed chunk fires a
lifecycle event that reserves a UI row, runs transcription, then kicks off
translation.

**Translation:** Apple's `Translation` framework, per-chunk, inline in the
lifecycle handler. Results are cached so repeated phrases (common in
meetings) don't re-hit the framework.

**TTS + streaming:** Finalized translations are synthesized by
`AVSpeechSynthesizer.write` (no local playback) only when at least one
listener is connected to `/live.wav` — synthesis is skipped entirely when
nobody is tuned in. Audio is streamed as 24 kHz PCM16 LE WAV over a
hand-rolled `NWListener` HTTP server.

**Crosstalk suppression:** Mic samples are zeroed while system audio is
active (250 ms window), so the mic track doesn't transcribe speaker bleed.

**Output:** Sentence timestamps are anchored to the paired `.wav` file via
a cumulative 16 kHz sample counter in the transcriber, so SRT cues and
JSONL `start`/`end` values line up sample-accurately with the audio.
Merged SRTs contain plain cue text — no `[Mic]`/`[Sys]` prefix on any
line, including the subtitle tracks embedded in the `.mkv`. At Stop,
ffmpeg wraps the WAVs + SRTs into an MKV and everything is zipped to
`~/Documents/LiveTranslate/<stamp>.zip`.

See [CLAUDE.md](CLAUDE.md) for the file-by-file map, architecture
diagram, and the lessons learned along the way.

## Debug log

```sh
tail -f /tmp/livetranslate.log
```
