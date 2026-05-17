# LiveTranslate

Floating, translucent macOS app that captures **your microphone *and* the
audio your Mac is playing** at the same time, transcribes them on-device
(or via Apple's server fallback), and translates the result into the
target language of your choice — all in one rolling, hover-able window.

Built with SwiftPM only — no Xcode project, no third-party dependencies.

![Stopped](docs/stopped.png)

![Running](docs/while_running.png)

## Build & run

```sh
./build.sh
open build/LiveTranslate.app
```

You need only the Command Line Tools (`xcode-select --install`); no
full Xcode required.

## ⚠️ One-time setup: download languages

Both transcription and translation rely on language packs that macOS
**only downloads on demand**. Do this *before* the first run or the app
will sit there silently:

1. **Speech recognition language** (e.g. German for transcribing German
   speech). Open
   **System Settings → Keyboard → Dictation**, click the **Edit…** button
   next to *Languages*, and add the source language. macOS downloads the
   on-device model in the background.

2. **Translation language pair** (e.g. German → English). Open
   **System Settings → Apple Intelligence & Siri → Translation Languages**
   (or, on slightly older macOS, **System Settings → General → Language &
   Region → Translation Languages**) and add both the source and target
   languages.

Without these downloads the recognizer will hit "No speech detected"
within a fraction of a second and the translation panel stays empty.

## Permissions

First launch prompts for, in order:
- **Microphone** — to capture your voice.
- **Speech Recognition** — to transcribe captured audio.
- **Screen Recording** — required by `ScreenCaptureKit` to access system
  audio. No screen frames are kept; only the audio stream is used.

## How it works (one-paragraph version)

The mic feeds an `AVAudioEngine` tap; system audio comes from
`ScreenCaptureKit` (audio-only configuration). Both are converted to
16 kHz mono Float32 and **sample-summed** with hardware-accelerated
`vDSP_vadd` so that one continuous audio stream reaches Apple's
`SFSpeechRecognizer`. Recognized sentences are translated per-sentence
via the `Translation` framework (cached by source text). Old sentences
fade out and eventually drop into a per-run JSONL archive — paired
with a `.wav` of the exact mixed audio the recognizer heard:

```
~/Documents/LiveTranslate/
    transcripts/<stamp>.jsonl
    recordings/<stamp>.wav
```

See [CLAUDE.md](CLAUDE.md) for full architectural notes, the things
that have bitten us, and the file-by-file map.

## Debug log

```sh
tail -f /tmp/livetranslate.log
```
