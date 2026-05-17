# LiveTranslate

Floating, translucent macOS app that captures your **microphone and
system audio** in parallel, transcribes both on-device via
[whisper.cpp](https://github.com/ggerganov/whisper.cpp), and translates
the result with Apple's `Translation` framework. Each session lands
as a single zip in `~/Documents/LiveTranslate/<stamp>.zip` containing
both `.wav`s, the per-source + merged SRTs, the JSONL log, and a
ready-to-watch `.mkv` (640×360 black background, both subtitle tracks
embedded).

![Default layout](docs/default.png)
![Compact layout](docs/compact.png)

Example session output: [youtu.be/jXrzOEh-zZU](https://www.youtube.com/watch?v=jXrzOEh-zZU)
— the `.mkv` shipped in the zip, uploaded to YouTube with the
extracted SRTs re-attached as caption tracks (YouTube ignores
subtitles embedded inside the container).

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
bundled model is `ggml-large-v3-turbo-q5_0.bin` (~570 MB) — distilled
large-v3 with 4 decoder layers, large-class quality at ~3× realtime
on Apple Silicon. Set `WHISPER_MODEL=…` before `./build.sh` and
update `WhisperCppTranscriber.bundledModelName` to match if you want
a different one.

## One-time macOS setup

- **Translation language pack.** Apple downloads pairs on demand —
  add yours under **System Settings → Apple Intelligence & Siri →
  Translation Languages** before first run, otherwise the translation
  panel stays empty.
- **Permissions** (Microphone + Screen Recording). Prompted on first
  launch.
- **Persistent permissions across rebuilds.** Ad-hoc signing churns
  the `cdhash` every build and macOS re-prompts. Create a self-signed
  cert in Keychain Access → Certificate Assistant (name e.g.
  `LiveTranslateDev`, Code Signing, Self Signed Root), then
  `export LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev` — `build.sh`
  picks it up.

## How it works (one paragraph)

Mic via `AVAudioEngine`, system via `ScreenCaptureKit`. Each stream
goes through its own `RNNoise` instance and an envelope-follower AGC
(SIMD via Accelerate). The two streams are kept independent end-to-end
— their own audio recorders, their own per-source SRT files, their
own `WhisperCppTranscriber.transcribe(...)` call (shared `ctx`,
`NSLock` around `whisper_full` so the two streams take turns). Whisper
is fed in 1–5 s chunks closed on silence; each closed chunk reserves a
UI row that flips through *listening → transcribing → translating*
and graduates to a final sentence. Mic samples during system
playback are zeroed upstream of the broadcaster (cross-talk gate), so
the mic `.wav` doesn't carry speaker bleed. At Stop, the work
directory is built into an MKV via ffmpeg's `amix` and zipped to
`~/Documents/LiveTranslate/<stamp>.zip`.

See [CLAUDE.md](CLAUDE.md) for the file-by-file map, architecture
diagram, and the lessons learned along the way.

## Debug log

```sh
tail -f /tmp/livetranslate.log
```
