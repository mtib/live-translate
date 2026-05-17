# LiveTranslate

Floating, translucent macOS app that captures **your microphone *and* the
audio your Mac is playing** at the same time, transcribes them on-device
(or via Apple's server fallback), and translates the result into the
target language of your choice — all in one rolling, hover-able window.

Built with SwiftPM and a CMake-driven dependency on
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) — no Xcode project required.

![Stopped](docs/stopped.png)

![Running](docs/while_running.png)

## Build & run

```sh
./build.sh
open build/LiveTranslate.app
```

Prerequisites:
- Apple Command Line Tools (`xcode-select --install`).
- CMake (`brew install cmake`). Used once on first build to compile
  whisper.cpp; cached after.

The first run of `./build.sh` clones whisper.cpp v1.7.4 into `external/`,
builds it into static libraries under `build/whisper-prefix/`, and
downloads the bundled `ggml-base-q5_1.bin` model (~57 MB) into
`build/whisper-models/`. The model is then copied into the `.app`'s
`Contents/Resources/` so the user doesn't need to fetch it separately.
The first build takes ~60-90 seconds. Subsequent builds skip these
steps and complete in a few seconds.

## ⚠️ One-time setup: translation language pack

Apple's `Translation` framework only downloads language pairs **on
demand**. Do this *before* the first run or the translation panel will
stay empty:

Open **System Settings → Apple Intelligence & Siri → Translation
Languages** (or, on slightly older macOS, **System Settings → General →
Language & Region → Translation Languages**) and add both your source
and target languages.

Transcription itself doesn't need any system download — whisper.cpp
runs against a model bundled inside the app. Just pick the source
language in the UI and start talking.

To use a larger / different whisper model, drop a GGML `.bin` named
`ggml-base-q5_1.bin` into `~/Documents/LiveTranslate/models/` — the app
picks that up in preference to the bundled default. Grab alternatives
(tiny, small, medium, large variants — quantized or full-precision)
from <https://huggingface.co/ggerganov/whisper.cpp>.

## Permissions

First launch prompts for:
- **Microphone** — to capture your voice.
- **Screen Recording** — required by `ScreenCaptureKit` to access system
  audio. No screen frames are kept; only the audio stream is used.

(Speech Recognition permission is no longer needed — Apple's Speech
framework isn't in the pipeline anymore.)

## How it works (one-paragraph version)

The mic feeds an `AVAudioEngine` tap; system audio comes from
`ScreenCaptureKit` (audio-only configuration). Both are converted to
48 kHz mono Float32 and **sample-summed** with hardware-accelerated
`vDSP_vadd`, then the summed stream is passed through a vendored
copy of [xiph/rnnoise](https://github.com/xiph/rnnoise) (a tiny
GRU-based denoiser, BSD 3-clause). The denoised stream is then
downsampled to 16 kHz mono and fed to
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) in chunks
(closed when the user pauses or after ~25 s of continuous speech).
Recognized sentences are translated per-sentence via Apple's
`Translation` framework (cached by source text). Old sentences fade out
and eventually drop into a per-run JSONL archive — paired with a `.wav`
of the exact denoised audio whisper saw:

```
~/Documents/LiveTranslate/
    transcripts/<stamp>.jsonl       (one sentence per line as JSON)
    transcripts/<stamp>.<src>.srt   (subtitles, source language)
    transcripts/<stamp>.<tgt>.srt   (subtitles, translated)
    recordings/<stamp>.wav          (mixed mic+system, post-denoise, 48 kHz mono)
```

The `.srt` files use cue times relative to the start of the matching
`.wav`, so you can drop them straight into a video player along with
the audio. They're also plain text — `grep -i term *.srt` works.

## Reviewing a run

VLC (and most other players) only render subtitles when there's a
video track to draw them onto, so a bare `.wav` + `.srt` won't show
captions. Easiest fix: wrap the run into a single MKV with a tiny
black "video", the audio, and **both** subtitle tracks embedded —
your player's *Subtitle → Sub Track* menu then switches between
languages on the fly.

One-liner from inside `~/Documents/LiveTranslate/`:

```sh
STAMP=2026-05-17_11-59-50   # ← change to the run you want

ffmpeg \
  -f lavfi -i color=c=black:s=960x180:r=2 \
  -i "recordings/${STAMP}.wav" \
  -i "transcripts/${STAMP}.de.srt" \
  -i "transcripts/${STAMP}.en.srt" \
  -map 0:v -map 1:a -map 2 -map 3 \
  -c:v libx264 -preset ultrafast -tune stillimage \
  -c:a copy -c:s srt \
  -metadata:s:s:0 language=deu \
  -metadata:s:s:1 language=eng \
  -disposition:s:0 default \
  -shortest "${STAMP}.mkv"
```

Adjust the two `language=` codes to match your actual source/target
(`deu`, `eng`, `fra`, `spa`, `nld`…). `-disposition:s:0 default` makes
the source-language subtitle the one VLC turns on by default; drop it
if you'd rather start with no subtitles visible.

If you specifically want subtitles **burned in** (one fixed language,
playable in any tool that can't toggle tracks):

```sh
ffmpeg \
  -f lavfi -i color=c=black:s=960x180:r=10 \
  -i "recordings/${STAMP}.wav" \
  -vf "subtitles=filename=transcripts/${STAMP}.en.srt" \
  -map 0:v -map 1:a \
  -c:v libx264 -preset ultrafast -tune stillimage -c:a aac \
  -shortest "${STAMP}.en.mp4"
```

(`subtitles=` requires an ffmpeg built with libass — the Homebrew
default. If you see *"No such filter: 'subtitles'"*, `brew reinstall
ffmpeg`.)

See [CLAUDE.md](CLAUDE.md) for full architectural notes, the things
that have bitten us, and the file-by-file map.

## Debug log

```sh
tail -f /tmp/livetranslate.log
```
