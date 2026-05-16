# Transcrybe DIY

A DIY on-device speech-to-text + translation app for macOS. No Xcode, just
SwiftPM + a build script.

## Build & run

```sh
./build.sh
open build/TranscrybeDIY.app
```

First launch will prompt for **Microphone** and **Speech Recognition**
permission, and on first use of a translation pair will also prompt for the
on-device translation model download. All processing is local.

## Architecture

See [CLAUDE.md](CLAUDE.md) for the full architectural overview, file map,
known gotchas, and contribution notes.

```
AudioSource → Transcriber → Pipeline → Translator → UI
   (mic)      (Apple Speech)            (Apple Translation)
```

Each stage is a protocol — drop in whisper.cpp / OpenRouter / ScreenCaptureKit
by writing a new conforming type and passing it to `Pipeline(...)`.

## Debug log

```sh
tail -f /tmp/transcrybe.log
```
