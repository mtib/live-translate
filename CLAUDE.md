# LiveTranslate — context for Claude

A minimal, no-Xcode macOS app that does on-device speech transcription and
translation from one or two audio sources at the same time. A learning / DIY
clone of [transcrybe.app](https://transcrybe.app).

> **Process rule for future edits**
>
> Any meaningful change to source layout, data flow, protocols, settings,
> or runtime behavior **must be reflected in this file in the same commit**.
> If you change `Sentence`'s shape, the pipeline order, the permissions
> needed, the build script, or any of the "Things that have bitten us"
> entries: update CLAUDE.md.
>
> The reason: this file is the only durable orientation document. Source
> comments cover *what* a function does; CLAUDE.md covers *why the design
> is shaped this way* and *what to never do again*. Future sessions read
> this first.

> **Eagerly load the Swift sources at session start**
>
> Before changing any code in this project, read **all** of
> `Sources/LiveTranslate/*.swift` and the relevant bridge headers. The
> data flow crosses several files (audio source → mixer → denoiser →
> transcriber → pipeline → translator → archives + UI), and surprising
> interactions live at the boundaries. Skimming or grepping for one
> symbol misses the patterns. Read everything first, *then* edit.

## How it's built

- **No `.xcodeproj`.** Pure SwiftPM plus a CMake-driven build step for
  whisper.cpp. Built with Command Line Tools (`/Library/Developer/CommandLineTools`)
  and Homebrew CMake (`brew install cmake`). No Xcode required.
- `swift-tools-version: 6.0`, but the executable target is pinned to
  `.swiftLanguageMode(.v5)` because the Translation APIs are awkward
  under Swift 6 strict concurrency.
- `./build.sh` first runs `tools/build-whisper.sh` (idempotent — clones
  whisper.cpp v1.7.4 into `external/`, builds static libraries into
  `build/whisper-prefix/`, downloads `ggml-base-q5_1.bin` into
  `build/whisper-models/`), then `swift build -c release`, then wraps
  the binary into `build/LiveTranslate.app/` with `Info.plist`, the
  GGML model copied into Resources, and ad-hoc codesign.
- **Always launch via `open build/LiveTranslate.app`** — never run the
  binary directly. TCC associates permission grants with the bundle,
  not the executable path; direct exec leads to the system thinking
  the usage-description keys are missing.

## Architecture

```
  Mic ──▶ Denoise ──▶ SourcePipeline(mic) ─┐
                       ├─ AudioRecorder    ─┤
                       ├─ Transcriber      ─┤── Sentence ──┐
                       └─ SRT writers      ─┘               │
                                                            ├─▶ @Published sentences: [Sentence]
  System ─▶ Denoise ─▶ SourcePipeline(sys) ─┐               │      │      ▲
                       ├─ AudioRecorder    ─┤── Sentence ──┘      ▼      │ writes translation back
                       ├─ Transcriber      ─┤                  Translator (per-sentence, cached)
                       └─ SRT writers      ─┘
                                                            ┌──▶ TranscriptArchive (.jsonl, source-tagged)
                                                            │       (on drop)
                                                            └──▶ per-source SRT (.srt, source-tagged)
```

Each stream stays **independent end-to-end** — mic and system never
mix. They share the whisper context (`NSLock` around `whisper_full`)
and the translation worker, but otherwise have their own audio
broadcasters, denoiser state, recorders, and SRT files.

### Key design decisions

- **Per-stream pipelines, never mixed.** Mic and system are captured
  in parallel, each runs through its own `RNNoise` (via
  `DenoisingAudioSource`), then a `SourcePipeline` ferries the
  per-source data: a `WhisperCppTranscriber.transcribe(...,source:)`
  call, an `AudioRecorder` writing `<stamp>.<source>.wav`, and per
  `(source, language)` SRT writers. Each `SourcePipeline` emits
  finished `Sentence`s via an `AsyncStream` that `Pipeline` consumes
  and merges into the shared UI array.
- **Audio format invariant.** Both sources standardize on **48 kHz
  mono Float32** (RNNoise's native rate). The transcriber downsamples
  to 16 kHz internally for whisper; each `.wav` writer downcasts to
  16-bit Int on the
  write path.
- **RNNoise on the merged stream.** A vendored copy of xiph/rnnoise
  v0.1.1 (BSD 3-clause, GRU weights embedded in `rnn_data.c`, ~400 KB
  static, zero runtime dependencies) runs inside `MixedAudioSource`
  right after the sample sum, before the broadcaster emits. That means
  the recognizer, the JSONL archive, and the `.wav` recorder all see
  the **post-denoise** signal. RNNoise wants ±32768-scaled Float32 in
  480-sample frames at 48 kHz — the wrapper (`RNNoiseProcessor`) buffers
  arbitrary input sizes and converts to/from our ±1 normalised range.
  Algorithmic latency: 10 ms.
- **whisper.cpp is the transcriber.** `WhisperCppTranscriber`
  downsamples the 48 kHz post-RNNoise stream to 16 kHz, runs an
  RMS-based VAD to segment into chunks (silence threshold
  `endChunkAfterSilence` ~0.7 s, hard cap `maxChunkSeconds` 5 s),
  trims and pads each chunk, then runs `whisper_full()` against the
  bundled GGML model. Whisper's internal segments are joined into
  one line per chunk; the chunk's audio-stream sample positions
  become the sentence's `startSeconds` / `endSeconds`, anchored by
  Pipeline at `runStartedAt` so JSONL/SRT timestamps map directly to
  positions in the paired `.wav`.
- **GGML model file resolution.** `WhisperCppTranscriber` looks for
  `~/Documents/LiveTranslate/models/ggml-large-v3-turbo-q5_0.bin`
  first (user override — drop a different model file there with the
  same name), then falls back to the `.app`'s bundled copy. Bundled
  default is large-v3-turbo Q5_0 (~570 MB). MIT licensed (Whisper
  weights from OpenAI, GGML packaging by ggerganov on Hugging Face).
  Copied into `Contents/Resources/` by `build.sh`.
- **Transcribers emit one sentence per closed chunk.** The
  transcriber owns chunk boundaries (via RMS) and the joining of
  whisper's internal segments. Pipeline never edits a `Sentence`
  in place; ingest just appends.
- **Translation cache.** `Pipeline.translationCache: [String: String]`
  keyed by source text. Identical strings across sessions reuse the
  cached translation. LRU-ish eviction at 200 entries.
- **Pruning.** Non-protected sentences whose `lastModified` is older
  than **60 s** get dropped once per second. Hard cap at **8** retained.
  "Protected" means: the most-recent sentence overall. `lastModified`
  is purely an in-memory freshness signal (the translation worker
  bumps it when the translation lands) and never written to disk —
  the JSONL `end` field comes from `endsAt` (audio-end time).
- **Per-run output files.** Each Start opens up to four paired files
  under one app-private root, sharing a `YYYY-MM-DD_HH-MM-SS` timestamp:

  ```
  ~/Documents/LiveTranslate/
      transcripts/<stamp>.jsonl       ← every dropped sentence
      transcripts/<stamp>.<src>.srt   ← SubRip subtitles, source language
      transcripts/<stamp>.<tgt>.srt   ← SubRip subtitles, target language
      recordings/<stamp>.wav          ← mixed mic+system audio
  ```

  The `.srt` files use cue times measured from the start of the
  recording (so they play in sync with the paired `.wav`) and are
  plain text — `grep` works as a transcript search tool. Skipped when
  source == target (no point translating into itself). SRT was chosen
  over WebVTT / LRC / custom plaintext because every video player
  (VLC, QuickTime, mpv, browsers via `<track>`, ffmpeg) reads it
  natively, AND it's readable enough to cat.

  The transcript line shape:
  ```json
  {"end":"2026-05-16T22:13:09.581Z","start":"2026-05-16T22:13:07.123Z","transcription":"…","translation":"…"}
  ```
  Keys sorted for grep/diff stability, ISO-8601 timestamps with
  fractional seconds. `start` / `end` are derived from the chunk's
  voiced span in the audio stream (anchored to `runStartedAt`), so
  they line up sample-accurately with the matching position in the
  paired `.wav`. The SRT cue uses the same offsets.
  `transcription` / `translation` always present; `translation` may be
  empty if the translator hadn't gotten to it yet.

  The `.wav` is 48 kHz mono signed-16-bit linear PCM (AVAudioFile auto-
  converts our Float32 buffers on the write path). Recording is taken
  **after** RNNoise, so one sample = exactly what the recognizer heard
  — audio and transcript line up. Paths are centralised in `Paths.swift`.

### Files

| File | Role |
|---|---|
| `App.swift` | `@main` entry. SwiftUI `Window` scene. Configures the NSWindow for floating / translucent / movable-from-background behavior. |
| `TranscriptView.swift` | The whole UI. Renders one `SentenceRow` per sentence, with opacity fade for older rows. Hosts `.translationTask` (the only way to get a `TranslationSession`). Background is a flat translucent color — no blur. |
| `Pipeline.swift` | `@MainActor ObservableObject` orchestrator. Owns the shared `sentences` array, the JSONL archive, the translator, and the prune loop. Spawns one `SourcePipeline` per `SourceTag` and merges their `Sentence` streams into the visible array. Persists user settings via UserDefaults. |
| `SourcePipeline.swift` | Self-contained per-stream pipeline (mic OR system). Owns its denoised audio source, recorder, source/target SRT writers, and a `transcribe()` call. Emits `Sentence`s via an `AsyncStream` that `Pipeline` consumes. |
| `BufferBroadcaster.swift` | Helper that fans audio buffers out to any number of subscribed `AsyncStream`s. `finishAll()` ends every subscription on audio-source stop, which is what drains the recognition pipeline naturally. |
| `Types.swift` | `SourceLocale`, `TargetLanguage`, `SourceTag` (mic/system), `Sentence`, `PipelineStatus`, `SessionSentence` / `SessionSnapshot`. Protocols: `AudioSource`, `Transcriber`, `Translator`. |
| `MicrophoneSource.swift` | `AVAudioEngine` mic capture, emits 48 kHz mono Float32. |
| `SystemAudioSource.swift` | `ScreenCaptureKit`-based system audio capture, emits 48 kHz mono Float32. |
| `DenoisingAudioSource.swift` | Wraps any `AudioSource`, applies its own `RNNoiseProcessor`, re-broadcasts. One per input stream so denoiser state is independent. |
| `RNNoiseProcessor.swift` | Swift wrapper around the vendored RNNoise C library. Owns the `DenoiseState`, buffers arbitrary-sized input into 480-sample frames, handles ±32768 ↔ ±1 scaling, emits denoised samples via `drain(into:count:)`. |
| `CRNNoise/` | Vendored xiph/rnnoise v0.1.1 as a SwiftPM C target. BSD 3-clause; GRU weights statically linked. See `Sources/CRNNoise/README.md`. |
| `WhisperCppTranscriber.swift` | **The transcriber.** Two structured-concurrency child tasks via `async let` (per `transcribe()` call): an accumulator that pumps audio and emits closed chunks on silence/max-chunk, and a worker that runs `whisper_full()`. Multiple concurrent calls (mic + system) share one `ctx` and serialize via `NSLock` around `whisper_full`. Per-source `previousChunkTail` keyed by `SourceTag` keeps `initial_prompt` context independent per stream. |
| `CWhisper/` | SwiftPM bridge target around `libwhisper.a` + `libggml*.a` produced by `tools/build-whisper.sh`. Headers (`whisper.h`, `ggml*.h`) are mirrored in by the build script and gitignored. |
| `AppleTranslator.swift` | Holds a `TranslationSession` that the View injects via `Pipeline.installTranslationSession(_:)`. |
| `TranscriptArchive.swift` | One-per-run JSONL archive. Rows carry a `source` field (`"mic"` / `"system"`) plus the audio-anchored `start`/`end` timestamps. |
| `AudioRecorder.swift` | One-per-stream `.wav` writer fed by a parallel consumer of its source's broadcaster. 48 kHz mono Int16. |
| `SubtitleArchive.swift` | One-per-`(source,language)` SRT writer. Cue times are offsets into the matching `<stamp>.<source>.wav`. |
| `Paths.swift` | Single source of truth for `~/Documents/LiveTranslate/{transcripts,recordings}/<stamp>.<source>[.<lang>].{wav,srt}` plus the shared `<stamp>.jsonl`. |
| `Log.swift` | Append-only file logger at `/tmp/livetranslate.log`. Truncates on launch if > 5 MB. |

## Key behaviors / non-obvious bits

### One chunk = one sentence

The RMS-based VAD in `WhisperCppTranscriber` already splits the audio
at natural pauses, so each chunk fed to `whisper_full()` is, by
construction, one utterance. Whisper's internal segmentation (it can
emit multiple `whisper_segment`s per call when it detects sub-pauses)
is joined into a single line before the snapshot leaves the
transcriber. The Pipeline gets one `SessionSentence` per closed
chunk, which lands as one `Sentence` row, which writes one JSONL line
and one SRT cue.

This also means: the transcriber owns sentence segmentation. The
Pipeline never splits, the Pipeline never edits-in-place.

### Audio-stream timing (SRT/JSONL ↔ WAV alignment)

The accumulator tracks a cumulative 16 kHz sample counter
(`samplesEverEmitted16k`) across all chunks; the chunk's own start
offset is the counter's value at chunk-open. From there the
sentence's `startSeconds` / `endSeconds` come from
`(chunkStartSample16k + voiceStart) / 16_000` etc. — i.e. **seconds
into the audio stream**.

Pipeline anchors those at `runStartedAt`, so `Sentence.createdAt /
endsAt` are wall-clock Dates but the **offsets between them and
`runStartedAt`** match audio-stream positions. The recorder consumes
the same audio broadcaster, so audio-stream position = WAV position.
SRT cues therefore line up sample-accurately with the `.wav` and the
JSONL `start`/`end` ISO timestamps are usable as audio offsets.

Backends that don't report timing pass `nil` for `startSeconds` /
`endSeconds` and Pipeline falls back to `Date()` at ingest — but
whisper.cpp always reports timing now, and there's no other backend.

### Concurrent accumulator + worker (the "second sentence dropped" bug)

Whisper takes 1-3 s to process a chunk. If we ran the audio pump
synchronously with whisper (close chunk → run whisper → resume pump),
any utterance during whisper's processing would be lost — the
upstream broadcaster keeps producing buffers but no one is consuming
the AsyncStream.

The fix is two structured child tasks under one `async let`:

- **Accumulator** reads audio forever, emitting closed chunks into a
  `AsyncStream<ChunkBuffer>` queue. Never blocked.
- **Worker** drains the queue, runs whisper serially, yields
  `SessionSnapshot`s back. Sees chunks in order.

The queue is unbounded; backpressure isn't a concern at our rates.

### Whisper hallucinates on silence

Trained on captioned video, the model fabricates phrases like "Thanks
for watching!" or "[Music]" given near-silent input. Three defences:

1. **Skip chunks with no voice** — `firstVoiceSample16k == nil`.
2. **Trim leading/trailing silence** off the chunk (with 100 ms of
   padding so word edges aren't clipped).
3. **Pad short trimmed clips with trailing zeros to ≥1.1 s.** Whisper
   silently returns zero segments for audio under ~1 s — its
   mel-spectrogram threshold is 100 frames at 10 ms each. Padded
   silence at the end is fine.

### `initial_prompt` continuity across chunks

The transcriber stashes the last ~120 chars of the previous chunk's
text as `previousChunkTail` and passes it as `params.initial_prompt`
on the next chunk. Stops the (aggressive) silence cuts from breaking
proper-noun or speaker-style continuity.

### Broadcaster pattern (the "won't restart after Stop" problem)
`AsyncStream` is single-consumer. The previous design exposed a single
stored AsyncStream as `buffers` — when a second consumer tried to read
from it after the first iterator was gone, it got no data. Both
`MicrophoneSource` and `SystemAudioSource` now build a fresh AsyncStream
per `buffers` access and fan tap callbacks out to all current subscribers.

### Translation framework quirks
- A `TranslationSession` is **only** obtainable via SwiftUI's
  `.translationTask` modifier. There is no public way to create one
  programmatically. We work around this by parking the modifier's closure
  on `Task.sleep(.max)` and stuffing the session into `AppleTranslator`
  for the Pipeline to use.
- First time a language pair is used, macOS prompts to download translation
  models. The user must accept. The download can be triggered ahead of time
  via **System Settings → Apple Intelligence & Siri → Translation Languages**
  or by opening the Translate app once.
- `Configuration` source/target use bare language codes (`"de"`, `"en"`),
  not full BCP-47 (`"de-DE"`). We trim the region in `translationConfig`.

### Persisted settings

User-facing settings are stored in `UserDefaults` and restored on launch:
`translateEnabled`, `source` (BCP-47 locale), `target` (language code +
display name). `compactMode` is stored separately via `@AppStorage`
because it's a pure View concern. Mic-on / system-on are no longer user
settings — both are always captured.

### Permissions
The bundle declares:
- `NSMicrophoneUsageDescription`
- `NSScreenCaptureUsageDescription` (for system audio via SCK)

Mic prompts via `AVCaptureDevice.requestAccess`. Screen recording
prompts when `SCStream.startCapture()` runs the first time. No speech
recognition permission — whisper.cpp runs locally against a bundled
GGML model and doesn't touch Apple's Speech APIs.

Reset stale grants with:
```sh
tccutil reset Microphone local.mtib.livetranslate
tccutil reset ScreenCapture local.mtib.livetranslate
```

### Window
- Real macOS app (not menu-bar). `LSUIElement = false`.
- Translucent (`NSVisualEffectView.Material.hudWindow`), floating
  (`NSWindow.level = .floating`), movable from anywhere
  (`isMovableByWindowBackground = true`), persists across Spaces
  (`canJoinAllSpaces`).
- Compact mode (`@AppStorage("compactMode")`) hides the controls and just
  shows the sentence list — useful as a slim hover overlay.
- **No in-window Quit / Copy / Clear buttons** — use the native macOS
  quit (Cmd+Q / app menu) and select text in a row to copy. The archive
  file is the durable record; no manual export needed.

## Tools / SDKs in use

- `AVAudioEngine`, `AVAudioConverter` — mic capture + sample-rate conversion
- `Accelerate` (`vDSP_vadd`) — SIMD per-sample sum in `MixedAudioSource`
- `ScreenCaptureKit` — system audio capture
- `Speech` (`SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`)
- `Translation` (`TranslationSession`, `.translationTask`)
- SwiftUI

## Roadmap (rough)

- [ ] Per-app audio capture (instead of whole-machine) via SCK's filter
- [x] RNNoise denoising on the merged stream (vendored, BSD 3-clause)
- [ ] whisper.cpp backend as an alternative `Transcriber` impl (in progress on `whisper-cpp` branch)
- [ ] OpenRouter fallback as an alternative `Translator` impl
- [ ] Global hotkey to start/stop
- [ ] Click-through floating overlay mode
- [ ] Persist transcript history

## Build / run / debug commands

```sh
./build.sh                                       # build & bundle
open build/LiveTranslate.app                     # launch (always via `open`!)
tail -f /tmp/livetranslate.log                      # see log output
pkill -f LiveTranslate                           # kill all instances
```

## Things that have bitten us already

1. **Running the binary directly** (not via `open`) loses bundle context,
   TCC complains about missing usage-description keys, app crashes on
   first permission request.
2. **Reinstalling the audio tap** between recognition sessions caused
   recognition to silently stop working after ~1 minute. Keep the tap
   permanent.
3. **`requiresOnDeviceRecognition = true`** hard-fails when the language
   model isn't installed yet. We set it to `false` so the system can fall
   back to cloud if needed.
4. **`NSLog`** doesn't reliably appear in `log show` for ad-hoc-signed
   apps on macOS 26. Use `Log.line(_:)` → `/tmp/livetranslate.log` instead.
5. **Command Line Tools don't ship XCTest or Swift Testing.** No `swift test`
   support without installing full Xcode. Tests deliberately omitted.
6. **Single-consumer AsyncStream** silently breaks every Start after the
   first one. Audio sources must broadcast to per-subscriber streams.
7. **Stalled when audio plays out the speakers and the mic source is on.**
   The recognizer choked on speaker bleed + room noise. Fix: use the
   System Audio source instead (ScreenCaptureKit).
8. **Index-only snapshot reconciliation** left orphan rows whenever the
   recognizer revised away a sentence boundary. Always handle the "snapshot
   shrunk" case explicitly.
9. **`DispatchSemaphore.wait()` on the MainActor to block on an async
   operation that itself hops to MainActor is an instant deadlock.** The
   first version of `SystemAudioSource.start()` did this; the app froze on
   Start when system audio was enabled. Rule: never block the main thread
   with a semaphore for async work. `AudioSource.start()` is now `async
   throws` so backends can implement it natively.
10. **"Don't drop active-session sentences" was too aggressive.** The
    original `prune` / `enforceMaxCount` exempted every sentence in the
    active recognition session — and since a session can run for ~60
    seconds emitting many sentences, the list kept growing forever. Only
    the *live* (last-active) sentence per source needs protection.
11. **Hoisting `let audio = source.buffers` out of the recognition-cycle
    while-loop** silently broke session restarts: `AsyncStream` is
    single-consumer, so the second session's pump task iterated an
    already-drained stream and the recognizer hit "No speech detected".
    Rule: `buffers` is a *fresh subscription factory* — call it per
    consumer, never cache.
12. **Unstructured `Task { ... }` children inside a cancellable parent
    don't inherit cancellation.** The original `run()` spawned its
    translation/prune workers and per-source recognition cycles as
    independent Tasks, then awaited their `.value`. When the parent
    Task was cancelled (via `Pipeline.stop()`), the await woke up but
    the child Tasks kept running independently — recognition continued
    producing transcripts, and a second Stop press would actually start
    a *fresh* run on top (creating a duplicate JSONL archive). Fix:
    spawn children inside `withTaskGroup` so cancellation cascades.
    Related rule: don't `runTask = nil` inside `stop()` — leave it set
    so `toggle()` no-ops during the wind-down rather than starting a
    new run on top.
13. **`CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` with
    `bufferListSize: MemoryLayout<AudioBufferList>.size` only fits ONE
    AudioBuffer.** ScreenCaptureKit delivers non-interleaved stereo
    Float32 — two separate AudioBuffers — which made the call fail with
    `kCMSampleBufferError_ArrayTooSmall` on *every* sample. Diagnostic
    counters (`SystemAudio: heartbeat received=X yielded=0 convFails=X`)
    were the giveaway. Fix: use
    `CMSampleBufferCopyPCMDataIntoAudioBufferList(_:at:frameCount:into:)`
    with `AVAudioPCMBuffer.mutableAudioBufferList` — the destination
    is already correctly sized for its format (separate buffers for
    non-interleaved, one for interleaved).
14. **Apple Speech serializes recognition tasks per-app — not just
    on-device.** Two concurrent `SFSpeechRecognizer`s preempt each
    other on every restart, both fast-failing with "No speech detected"
    within ~0.3 s. Forcing one to the server (via
    `recognizer.supportsOnDeviceRecognition = false`) does NOT help —
    the contention is at the recognition-task level, not the on-device
    model level. The only fix that works is to send a **single mixed
    audio stream to one recognizer**. We did that via `MixedAudioSource`.
    Trade-off: source attribution is lost (we removed `SentenceKind`
    and color-coding from the UI as part of this).
15a. **`SFTranscriptionSegment.timestamp` / `.duration` are zero on
    partial results.** Apple only populates them on final results.
    Pause-based sentence splitting in `splitIntoSentences` therefore
    only fires when a recognition session ends (~60 s on-device, sooner
    on errors/restarts) — at that point the text gets retroactively
    re-split using the gaps. During a live session only punctuation
    splits fire. Confirmed by dumping `[timestamp+duration substring]`
    for every snapshot; partials looked like
    `[0.00+0.00 Hello] [0.00+0.00 world]…` until the final result came
    in with real timings. No fix from our side; just a known limit.
15. **Naive "interleave buffer streams" mixing tanked recognition
    latency.** Forwarding every upstream buffer as it arrived doubled
    the recognizer's audio-time-to-wall-time ratio (it received ~2 s of
    audio per real second). Transcription content was correct but
    emission lagged badly. Fix: mix at the SAMPLE level — mic clocks
    the output, each mic buffer produces one summed output buffer,
    system samples are pulled from a small bounded queue and added per-
    sample. 1:1 audio-to-wall ratio restored, recognition is instant
    again. The per-sample sum runs through `vDSP_vadd` (Accelerate) on
    a reusable `UnsafeMutablePointer<Float>` scratch buffer — SIMD on
    NEON / AVX, no per-call malloc.
