# LiveTranslate — context for Claude

A minimal, no-Xcode macOS 15+ floating app for on-device speech transcription and
translation from one or two audio sources simultaneously. A learning / DIY clone of
[transcrybe.app](https://transcrybe.app).

---

## ┌─ RULE 1: Keep this file accurate ───────────────────────────────────┐
## │ Update CLAUDE.md in the same commit as any meaningful code change.  │
## │ What counts as "meaningful": source file layout, data-flow changes, │
## │ new or changed protocols, settings keys, build pipeline, runtime    │
## │ behavior, the files table, or any new entry in "Things That Bit Us".│
## │ This file is the ONLY durable orientation document. It is read by   │
## │ AI agents at session start; stale content directly misleads them    │
## │ into making wrong assumptions about the codebase. Source comments   │
## │ cover *what* a function does; CLAUDE.md covers *why the design is   │
## │ shaped this way* and *what to never do again*.                      │
## └──────────────────────────────────────────────────────────────────────┘

## ┌─ RULE 2: Persist learnings ──────────────────────────────────────────┐
## │ Every bug that bites gets a numbered entry in "Things that have     │
## │ bitten us": what went wrong AND the shape of the fix. This is the  │
## │ durable institutional memory. Without it the same trap is re-       │
## │ stepped in a later session. Mark historical entries (for approaches │
## │ no longer in use) clearly so they are still readable as warnings.   │
## └──────────────────────────────────────────────────────────────────────┘

## ┌─ RULE 3: Eagerly load Swift sources at session start ────────────────┐
## │ Before changing any code, read ALL of                               │
## │   Sources/LiveTranslate/*.swift                                     │
## │ and the relevant bridge headers. The data flow crosses many files   │
## │ (audio source → denoiser → transcriber → pipeline → translator →   │
## │ archives + UI), and surprising interactions live at the boundaries. │
## │ Skimming or grepping for one symbol misses the patterns.            │
## └──────────────────────────────────────────────────────────────────────┘

## ┌─ RULE 4: Always build with signing identity ─────────────────────────┐
## │ Non-interactive bash (the agent's Bash tool) does NOT source        │
## │ ~/.zshrc, so the env var is NOT set unless you pass it explicitly.  │
## │ Every build the agent triggers without it is ad-hoc-signed,         │
## │ producing a fresh cdhash, which causes macOS to re-prompt for mic   │
## │ and screen-recording permissions on every run. Always prefix with:  │
## │                                                                     │
## │   LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh           │
## └──────────────────────────────────────────────────────────────────────┘

---

## How it's built

- **No `.xcodeproj`.** Pure SwiftPM plus a CMake-driven build step for
  whisper.cpp. Built with Command Line Tools (`/Library/Developer/CommandLineTools`)
  and Homebrew CMake (`brew install cmake`). No Xcode required.
- `Package.swift` declares `swift-tools-version: 6.0`. The `LiveTranslate`
  executable target is pinned to `.swiftLanguageMode(.v5)` because the
  Translation and AVAudioPCMBuffer APIs are awkward under Swift 6 strict
  concurrency. The two C targets (`CRNNoise`, `CWhisper`) are unaffected.
- **Three targets** in Package.swift:
  - `CRNNoise` — vendored xiph/rnnoise v0.1.1 (BSD 3-clause). C sources in
    `Sources/CRNNoise/`, GRU weights embedded in `rnn_data.c`. Build uses
    `-Wno-implicit-function-declaration` and `-Wno-null-dereference` for
    upstream idioms.
  - `CWhisper` — thin bridge target linking against the static libs produced by
    `tools/build-whisper.sh`. Headers live in `Sources/CWhisper/include/`
    (mirrored from `build/whisper-prefix/include/` by the build script on every
    run). Linker flags: `-lwhisper -lggml -lggml-base -lggml-cpu -lggml-blas
    -lggml-metal -lc++`, plus `Metal`, `MetalKit`, `Foundation`, `Accelerate`
    frameworks.
  - `LiveTranslate` — the app itself, depends on `CRNNoise` and `CWhisper`.
- **`tools/build-whisper.sh`** (idempotent, called by `build.sh`):
  - Clones whisper.cpp **v1.7.4** (`--depth 1 --branch v1.7.4`) into
    `external/whisper.cpp` if not present.
  - Configures with CMake (`GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`,
    `GGML_ACCELERATE=ON`, `GGML_NATIVE=OFF` — native off because it broke
    some Apple-Silicon CI builds). Builds static libs into `build/whisper-prefix/`.
  - Always mirrors `build/whisper-prefix/include/*.h` into `Sources/CWhisper/include/`
    (unconditional, outside the idempotency guard — branch switching can wipe
    that dir while leaving the prefix on disk; re-copying every run is cheap).
  - Downloads the GGML model into `build/whisper-models/` if not already there.
    Prefers `models/<MODEL_NAME>` (local cache populated by `dev-setup.sh`).
    Default model: `ggml-large-v3-turbo-q5_0.bin` from Hugging Face
    (`ggerganov/whisper.cpp`).
- **`build.sh`**:
  1. Runs `tools/build-whisper.sh`.
  2. `swift build -c release`.
  3. Assembles `build/LiveTranslate.app/` (MacOS binary + `Info.plist` + GGML
     model in `Contents/Resources/` + `icon.icns`).
  4. Codesigns: ad-hoc (`-`) by default; uses `LIVETRANSLATE_SIGN_IDENTITY` if
     set. Model filename in `Contents/Resources/` must match
     `WhisperCppTranscriber.bundledModelName` (currently
     `"ggml-large-v3-turbo-q5_0"`).
- **`dev-setup.sh`** — pre-downloads a curated set of GGML models into `models/`
  (gitignored). Running it once avoids repeated downloads when switching model
  variants.
- **Always launch via `open build/LiveTranslate.app`** — never run the binary
  directly. TCC associates permission grants with the bundle, not the executable
  path; direct exec leads to the system thinking usage-description keys are
  missing.

---

## Architecture diagram

```
  Mic ──────▶ MicrophoneSource ──▶ DenoisingAudioSource(mic)
                (AVAudioEngine)      (RNNoise + AGC + crosstalk gate)
                                          │
                                          ├──▶ AudioRecorder → <stamp>.mic.wav
                                          │
                                          └──▶ WhisperCppTranscriber.transcribe()
                                                    │   accumulator task
                                                    │   ↓ ChunkBuffer
                                                    │   worker task → whisper_full()
                                                    │   ↓ onChunkLifecycle callback
                                                    │
  System ──▶ SystemAudioSource ──▶ DenoisingAudioSource(system)
              (ScreenCaptureKit)     (RNNoise + AGC, no mute gate)
                                          │
                                          ├──▶ AudioRecorder → <stamp>.system.wav
                                          │
                                          └──▶ WhisperCppTranscriber.transcribe()
                                                    │   (shares same ctx + NSLock)
                                                    │   ↓ onChunkLifecycle callback
                                                    │
                Both streams ──────────────────────▶ Pipeline.handleChunkLifecycle
                                                           │ (hops to MainActor)
                                                           ▼
                                                   Pipeline.applyLifecycle
                                                           │
                                         ┌─────────────────┼──────────────────┐
                                         ▼                 ▼                  ▼
                                  .listening         .transcribing       .completed(text)
                                  (reserve row)      (flip row)          → translate (or cache hit)
                                                                          → graduate()
                                                                               │
                                                    ┌──────────────────────────┤
                                                    ▼                          ▼
                                           @Published sentences        TranscriptArchive.append
                                           (UI rows)                   (JSONL, source-tagged)
                                                    │
                                                    ├──▶ MergedSubtitleArchive.add (per lang)
                                                    │
                                                    └──▶ LiveAudioServer.publishTranscript (SSE)
                                                              │
                                                              ├── / → HTML listen page
                                                              ├── /live.wav → open WAV stream
                                                              └── /events → SSE transcript
                                                                                │
                                                              TTSSpeaker ──────▶ /live.wav
                                                              (AVSpeechSynthesizer, no local
                                                               playback, 24 kHz PCM16 LE)
```

Both streams share **one `WhisperCppTranscriber` instance** (and thus one
`whisper_context *`). `whisper_full` invocations serialize via `NSLock`. The UI
sees in-flight chunks as reserved rows that flip through `.listening →
.transcribing → .translating`, then graduate to a `Sentence` with a **fresh**
UUID (not the chunk's UUID — reusing it would collide in SwiftUI's `LazyVStack`).

---

## Key design decisions

- **Per-stream pipelines, never mixed.** Mic and system audio are captured in
  parallel, each going through its own `DenoisingAudioSource` (independent
  RNNoise instance + AGC) and its own `SourcePipeline` (AudioRecorder +
  `transcriber.transcribe()` call). The transcribers share one whisper `ctx` via
  `NSLock`. No sample mixing. No attribution loss. The JSONL `source` field
  tracks which stream produced each sentence.

- **Inflight-chunk UI model (UUID continuity through graduation).** Every chunk
  reserves a UI row at voice onset (state `.listening`, with a UUID generated at
  that moment). That UUID flows through `.transcribing` and `.translating(text)`
  events. On translation completion, `graduate()` appends a `Sentence` with a
  **fresh** UUID and removes the inflight entry — SwiftUI sees a smooth content
  swap without an abrupt remove+add. Chunks whisper rejects (no voice, too short,
  zero segments) fire `.dropped` and the reserved row collapses out.

- **Lifecycle callback, not snapshot stream.** `WhisperCppTranscriber` emits
  `onChunkLifecycle(chunkID, source, event)` from background tasks. `Pipeline`
  receives it via `handleChunkLifecycle` (a `nonisolated` function) which
  dispatches `Task { @MainActor in applyLifecycle(...) }`. The `AsyncThrowingStream<SessionSnapshot>` returned by `transcribe()` is drained but
  its values are ignored — the lifecycle callback is the single source of truth.
  This is what lets per-chunk async translation fit cleanly into the state machine.

- **Audio format invariant: 48 kHz mono Float32.** Both `MicrophoneSource` (via
  AVAudioEngine tap + AVAudioConverter) and `SystemAudioSource` (via SCK +
  AVAudioConverter) produce 48 kHz mono Float32 — RNNoise's native rate.
  `WhisperCppTranscriber` downsamples to 16 kHz internally using a per-run
  `WhisperResampler` (AVAudioConverter, stateful across chunks to avoid filter
  discontinuities). `AudioRecorder` writes 48 kHz 16-bit int (AVAudioFile
  auto-converts Float32 on write).

- **RNNoise per stream.** `DenoisingAudioSource` wraps any `AudioSource`, applies
  its own `RNNoiseProcessor` (one `DenoiseState *` per instance), and re-broadcasts
  via its own `BufferBroadcaster`. RNNoise processes 480-sample frames at 48 kHz
  (10 ms algorithmic latency). Input must be ±1 Float32; the wrapper handles
  ±32768 scaling in `feed()` / `drain()`. Denoising before mixing was the old
  design; independent per-stream denoisers let the GRU adapt to mic room noise vs.
  system ambient independently.

- **AGC (Accelerate, envelope follower, targets 0.1 RMS, 8× cap).** Each
  `DenoisingAudioSource` runs a post-RNNoise AGC per instance: measure RMS via
  `vDSP_measqv`, EMA the input level on voiced buffers only (`agcNoiseFloor =
  0.003`), target `agcTargetRMS = 0.1`, smooth the applied gain with
  `agcGainSmoothing = 0.06` EMA, apply via `vDSP_vsmul`. `agcMinGain = 1.0`
  (never attenuates), `agcMaxGain = 8.0`. AGC happens before the crosstalk
  mute gate so the gate produces true silence, not amplified noise.

- **Crosstalk gate on mic.** `Pipeline` wires `DenoisingAudioSource(mic)` with a
  `muteWhen: { whisper?.isSystemRecentlyVoiced() }` closure. When system audio
  was voiced within `crosstalkPersistSeconds` (250 ms), the mic's outgoing buffer
  is zeroed with `memset` after denoising (so the RNNoise GRU stays coherent) but
  before emission. Both consumers — `AudioRecorder` and the transcriber's
  accumulator — see the muted buffer. The system accumulator calls
  `markSystemVoiced()` on each buffer whose RMS clears `silenceRMSThreshold`.

- **whisper.cpp: RMS VAD, chunk sizes, silence-close gating, padding.** The
  accumulator runs a per-buffer RMS check (`silenceRMSThreshold = 0.012`). A
  chunk closes on `endChunkAfterSilence` (0.7 s) of consecutive quiet frames,
  but only after the chunk has grown past `minWhisperInputSeconds` (1.1 s) total
  — without this gate, short utterances like "yes" would silence-close instantly
  with too little audio. Hard cap at `maxChunkSeconds` (5 s). The worker trims
  leading/trailing silence (±`voicePaddingSeconds` = 100 ms) and pads clips
  shorter than 1.1 s with trailing zeros — whisper silently returns zero segments
  for audio under ~1 s (100 mel frames × 10 ms). Minimum voiced-sample check:
  `minVoicedSeconds = 0.1 s` (to pass single-syllable utterances like "Ja").

- **GGML model: bundled, one file.** `WhisperCppTranscriber.bundledModelName =
  "ggml-large-v3-turbo-q5_0"` (the `.bin` extension is added by
  `Bundle.main.url(forResource:withExtension:)`). Default size ~570 MB. Distilled
  large-v3 with 4 decoder layers vs. 32 in full large; large-class quality at
  ~3× realtime on Apple Silicon. Metal GPU used (`params.use_gpu = true`),
  `flash_attn = false`. To swap: edit `bundledModelName` in
  `WhisperCppTranscriber.swift` AND `WHISPER_MODEL` env var (consumed by both
  `build.sh` and `tools/build-whisper.sh`). No runtime model-picker; what you
  built is what you run.

- **Concurrent accumulator + worker.** `transcribe()` spawns two structured child
  tasks via `async let`: the *accumulator* pumps audio forever and emits closed
  `ChunkBuffer`s into an unbounded `AsyncStream<ChunkBuffer>`; the *worker* drains
  that queue and runs `whisper_full()` serially. The accumulator is never blocked
  on whisper. The whole thing runs off-MainActor (the task spawned inside the
  `AsyncThrowingStream` continuation is not inherited — there is no `Task.detached`
  needed at the outer level, but `runWhisperLocked` uses `Task.detached` for the
  `NSLock` calls).

- **One chunk = one sentence; transcriber owns segmentation.** The RMS VAD already
  splits at natural pauses, so each chunk is one utterance. Whisper's internal
  segments (it can emit multiple per call) are joined into a single line with
  `joined(separator: " ")`. Pipeline never splits or edits a `Sentence` in place;
  ingest just appends.

- **`initial_prompt` continuity per source.** `previousChunkTail: [SourceTag:
  String]` stores the last `maxInitialPromptChars` (120) chars of each stream's
  previous chunk text and passes it as `params.initial_prompt` on the next call.
  Per-source because mic and system content is unrelated — mixing them would
  pollute both transcribers.

- **Translation: per-chunk inline, `@MainActor` load-bearing.** When
  `.completed(text, startSeconds, endSeconds)` fires in `applyLifecycle`, the
  pipeline either graduates immediately (src == tgt language, or cache hit) or
  sets the inflight row to `.translating(text)` and dispatches `Task { @MainActor
  [weak self] in translator.translate(text) }`. The explicit `@MainActor` is
  load-bearing: without it, Swift 5 actor-inheritance heuristics can let the
  post-await `graduate` run off-actor, and `@Published` mutations from the wrong
  actor don't surface in the UI.

- **Translation cache: 200 entries, LRU-ish.** `Pipeline.translationCache:
  [String: String]` keyed by source text. On eviction (count > 200), drops
  ~10% of entries by insertion order (oldest first via `keys.prefix(toDrop)`).

- **Live translated-audio HTTP stream (opt-in by capability).** At run start,
  `Pipeline` calls `TTSSpeaker.bestVoice(forTargetCode: tgtLangCode)`. If a
  Premium or Enhanced voice is installed for the target AND `srcLang != tgtLang`,
  it spins up `LiveAudioServer` on port 8765 and a `TTSSpeaker`. If no voice is
  installed, the whole feature is skipped — the stream icon stays hidden.
  `ttsActive` is `true` while `ttsSpeaker != nil && ttsListenerCount > 0`.
  TTS synthesis is gated on `server.audioListenerCount > 0` — the speaker is
  never called when nobody is tuned in. `liveStreamURL` is published for the
  UI's share popover (URL + QR code via CoreImage).

- **`LiveAudioServer` routing.** Routes: `/` → dark-mode HTML listen page (self-
  contained HTML/CSS/JS, served once per connection); `/live.wav` → open-ended
  WAV stream (24 kHz mono PCM16 LE, `0xFFFFFFFF` data-chunk size, 200 ms
  heartbeat of 50 ms silence = 2400 bytes to keep VLC alive, 100 ms idle
  threshold); `/events` → SSE stream (one JSONL line per sentence, 200-entry
  replay buffer for late subscribers, 5 s `: ping` keepalive via 25 × 200 ms
  ticks). `audioListenerCount` and `onAudioListenerCountChanged` let Pipeline
  gate TTS. `publishTranscript(jsonLine:)` broadcasts to SSE subscribers and
  buffers for replay. URL resolution: tries private-range IPv4 first (walks
  `getifaddrs`, skips `utun`/`ipsec`/`tun` interfaces), falls back to `scutil
  --get LocalHostName` + `.local`, finally `localhost`.

- **`TTSSpeaker`.** Uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` —
  delivers raw `AVAudioPCMBuffer`s without engaging an output device (no local
  playback). One `AVAudioConverter` per utterance (not per buffer) so resampler
  state is continuous. Converts to 24 kHz mono PCM16 LE. Serial queue: one
  utterance completes before the next starts, with a 0.5 s gap between utterances
  (so the client has time to consume buffered audio before the next starts). Max
  pending queue: 5 utterances; oldest are dropped when over limit. Voice selection
  via `bestVoice(forTargetCode:)`: filters installed voices by primary subtag
  match, ranks Premium > Enhanced > Default. Pre-warms on init by synthesizing
  a silent utterance.

- **Pruning.** Non-protected sentences older than `maxAgeSeconds` (300 s = 5 min,
  keyed on `lastModified`) are removed once per second in `runPruneLoop`. Hard
  cap at `maxSentenceCount` (50) enforced in `enforceMaxCount` (called on each
  `graduate`). "Protected" = the last `Sentence` in the array (so the UI is never
  briefly empty mid-stream). Only the most-recent sentence is protected.

- **Per-run output: temp dir → MKV via ffmpeg → zip.** Each session writes into
  `NSTemporaryDirectory()/livetranslate-<stamp>/`. Sentences are archived to JSONL
  immediately on `graduate` (not at prune time). At Stop: flush writers → ffmpeg
  MKV → `/usr/bin/zip -j -q -X` into `~/Documents/LiveTranslate/<stamp>.zip` →
  delete temp dir. `shippedFiles` = `[transcript (.jsonl), mkvOutput (.mkv)]`.
  Per-source WAVs and merged SRTs are intermediates consumed by ffmpeg, not
  shipped. If ffmpeg isn't installed, no MKV; zip contains only JSONL.

- **Crash recovery.** `CrashRecovery.recoverPendingSessions()` (called
  `Task.detached` from `App.init`) scans `NSTemporaryDirectory()` for leftover
  `livetranslate-<stamp>/` dirs and runs the same MKV+zip+cleanup path for each.
  Idempotent: if the zip already exists it just deletes the leftover dir.

- **`TranscriptArchive.encodeLine(_:)` is static.** Used both by `append(_:)` (for
  disk writes) and by `Pipeline.recordSentence` (for SSE broadcast), ensuring the
  on-disk JSONL and the over-the-wire SSE event are bit-identical. The JSONL
  record shape has five fields with sorted keys (grep/diff stable):
  `end`, `source`, `start`, `transcription`, `translation`.

- **Broadcaster pattern.** `BufferBroadcaster` fans one audio tap callback to any
  number of `AsyncStream` subscribers. Each `var buffers: AsyncStream` access
  creates a fresh stream and registers a new continuation. `finishAll()` closes
  every subscriber's stream on `stop()`, driving natural drain rather than
  task cancellation.

- **Persisted settings.** `source` (BCP-47 `SourceLocale`) and `target`
  (`TargetLanguage`) are stored as JSON in `UserDefaults` (keys `pipeline.source`,
  `pipeline.target`). Default: `de-DE` source, `en` target. `compactMode` is
  stored via `@AppStorage("compactMode")` (View concern). Changing source or
  target while running triggers `requestRestartIfRunning()` → `stopActiveSources()`
  → deferred restart in `run()`'s defer block.

- **Window behavior.** `.floating` level, `isMovableByWindowBackground = true`,
  `canJoinAllSpaces`, `fullScreenAuxiliary`, hidden title bar, all traffic lights
  hidden, `fullSizeContentView`. No in-window Quit/Copy/Clear buttons; use Cmd+Q.
  Text rows have `.textSelection(.enabled)`. Compact mode (`@AppStorage`) hides
  language pickers and shows a slim bar.

---

## Files table

| File | Role |
|---|---|
| `App.swift` | `@main` entry. Initialises `Log`, fires `CrashRecovery.recoverPendingSessions()` as a background `Task.detached`. Creates the `Window` scene with `Pipeline`. Installs `NSApplication.willTerminateNotification` observer to call `pipeline.flushPendingSentences()` on Cmd+Q. Configures `NSWindow` (floating, translucent, movable, canJoinAllSpaces, traffic lights hidden). Has a `Debug` menu (`Cmd+Shift+D` = load fixture sentences, `Cmd+Shift+K` = clear). |
| `TranscriptView.swift` | Full UI. Renders `SentenceRow` (completed sentences) then `InflightRow` (in-flight chunks) in a `LazyVStack`/`ScrollView`. Two layouts: full (controls bar + list) and compact. Hosts `.translationTask(translationConfig)` — the only way to get a `TranslationSession`. Parks the closure with `AsyncStream<Never>.makeStream()` + `for await _ in parked { }` (see quirks section). Calls `pipeline.installTranslationSession(session)`. Renders `StreamShareView` popover (URL + CoreImage QR). `translationConfig` uses 2-letter primary subtag from BCP-47 source code. |
| `Pipeline.swift` | `@MainActor ObservableObject` orchestrator. Owns `@Published sentences`, `inflightChunks`, `status`, `isActive`, `liveStreamURL`, `ttsActive`. Runs the full session lifecycle in `run()`: permissions → `DenoisingAudioSource` init → audio start → open output files → build `SourcePipeline`s + `MergedSubtitleArchive`s → optional TTS/LiveAudioServer → prune loop → `withTaskGroup` over `SourcePipeline.run()` → cancel prune loop → flush + MKV + zip. Implements `applyLifecycle`, `graduate`, `recordSentence`, `cacheTranslation`, `prune`, `enforceMaxCount`. Wires `WhisperCppTranscriber.onChunkLifecycle`. |
| `SourcePipeline.swift` | Self-contained per-stream coordinator (mic OR system). Owns its denoised audio source, `AudioRecorder`. Runs recording and transcription loops concurrently via `async let`. The `AsyncThrowingStream` from `transcribe()` is drained but ignored — lifecycle events go via the transcriber callback to `Pipeline` directly. `flush()` delegates to recorder. |
| `BufferBroadcaster.swift` | Fan-out for audio buffers. `NSLock`-guarded `[UUID: AsyncStream.Continuation]`. Each `var stream` access creates a fresh `AsyncStream` and registers itself. `emit(_:)` snapshots continuations and yields outside the lock. `finishAll()` closes all continuations — this is the graceful-drain signal that lets the pipeline wind down without task cancellation. |
| `Types.swift` | `SourceLocale` (BCP-47 wrapper), `TargetLanguage` (code + name), `SourceTag` (mic/system, with `shortLabel` and `iconSystemName`), `InflightChunk` (with `State: listening / transcribing / translating(text:)`), `SessionSentence` (text, isFinal, startSeconds?, endSeconds?), `SessionSnapshot`, `Sentence` (id, text, translation, source, createdAt, endsAt, lastModified), `PipelineStatus` (idle/requestingPermissions/starting/running/finalizing/stopped). Protocols: `AudioSource`, `Transcriber`, `Translator`. |
| `MicrophoneSource.swift` | `AVAudioEngine` mic capture. Installs a tap on `engine.inputNode`, converts native format → 48 kHz mono Float32 via `AVAudioConverter`, emits via `BufferBroadcaster`. `stop()` removes tap, stops engine, calls `broadcaster.finishAll()`. |
| `SystemAudioSource.swift` | `ScreenCaptureKit`-based system audio capture. `SCStreamOutput` + `SCStreamDelegate`. Config: 48 kHz, 2 channels, tiny 2×2 video (SCK requires some video config; samples ignored). Converts SCK `CMSampleBuffer` → 48 kHz mono Float32 via `AVAudioPCMBuffer.fromCMSampleBuffer(_:format:)` + `AVAudioConverter`. Uses `CMSampleBufferCopyPCMDataIntoAudioBufferList` (see lesson #13). `stop()` calls `stream.stopCapture()` then `broadcaster.finishAll()`. |
| `DenoisingAudioSource.swift` | Wraps any `AudioSource`. Applies `RNNoiseProcessor`, optional AGC (`vDSP_measqv` + `vDSP_vsmul`, targets 0.1 RMS, max 8× gain), optional crosstalk `muteWhen` gate (mic only). Maintains its own `BufferBroadcaster`. Pump task (`Task`) pulls from upstream broadcaster, denoises, re-emits, calls `broadcaster.finishAll()` on upstream end. `stop()` awaits upstream stop then awaits pump task. |
| `RNNoiseProcessor.swift` | Thin Swift wrapper around RNNoise C API. Owns `DenoiseState *`. Buffers arbitrary-sized input into 480-sample frames, handles ±32768 ↔ ±1 Float32 scaling. `feed(samples:count:)` / `drain(into:count:)` API. 10 ms algorithmic latency. |
| `CRNNoise/` | SwiftPM C target. Vendored xiph/rnnoise v0.1.1, BSD 3-clause. GRU weights statically linked from `rnn_data.c`. See `Sources/CRNNoise/README.md`. |
| `WhisperCppTranscriber.swift` | The only `Transcriber` implementation. Loads GGML model lazily via `ensureContextLoaded()` (serialized by `ctxLoadLock: NSLock`). Two structured child tasks per `transcribe()` call: accumulator (VAD + chunk emission) and worker (whisper_full). Shares `ctx` across concurrent calls; `whisperLock: NSLock` serializes `whisper_full`. Implements `onChunkLifecycle` callback. Per-source `previousChunkTail: [SourceTag: String]` for `initial_prompt`. Cross-talk state: `lastSystemVoicedAt: Date` + `crosstalkLock: NSLock`. `runWhisperLocked` dispatches to `Task.detached` (cooperative-pool thread) to allow `NSLock.lock()`. Tunables are all `static var` (testable/overridable). Includes `WhisperResampler` (private, stateful `AVAudioConverter` for 48→16 kHz). |
| `CWhisper/` | SwiftPM bridge target. Headers (`whisper.h`, `ggml*.h`) mirrored from `build/whisper-prefix/include/` by build script. Links `libwhisper.a`, `libggml*.a`. |
| `AppleTranslator.swift` | `@MainActor Translator`. Holds a `TranslationSession?` injected by `Pipeline.installTranslationSession(_:)`. `translate(_:)` calls `session.translate(text)` and returns `response.targetText`. Throws `TranslateError.noSession` if no session yet. |
| `TranscriptArchive.swift` | One-per-run JSONL writer. `append(_:)` is async (serial `DispatchQueue`). Static `encodeLine(_:)` produces the JSON string without disk IO — used by both `append` and `Pipeline.recordSentence` for SSE, keeping on-disk and over-wire representations identical. Record shape (sorted keys): `end`, `source`, `start`, `transcription`, `translation`. `flush()` calls `queue.sync {}`. |
| `AudioRecorder.swift` | Per-stream WAV writer. `AVAudioFile(forWriting:settings:)` with 48 kHz mono 16-bit int PCM settings; `AVAudioFile.write(from:)` converts Float32 on the write path. `flush()` runs `queue.sync { self.file = nil }` — closing the file finalizes the WAV header data-chunk length (required for `MKVExporter` to probe duration correctly). |
| `SubtitleArchive.swift` | Per-`(source, language)` SRT writer. Appends `counter / start --> end / text` cues. Cue times are offsets into the matching `<stamp>.<source>.wav`. Currently not actively used (SRT writing was moved to merged-only flow); kept for future per-source SRT revival. |
| `MergedSubtitleArchive.swift` | Live-merged SRT per language (both sources interleaved). On each `add(text:startSeconds:endSeconds:)`: appends cue, re-sorts by start, rewrites file atomically. `flush()` awaits the write queue. Used by `MKVExporter`. |
| `MKVExporter.swift` | Shells out to ffmpeg (checks `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`). Builds 640×360 black H.264 + amix'd audio + embedded SRT tracks. Uses AVFoundation to probe WAV durations for `-t` bound on the lavfi video source. Also contains `ZipArchiver` (uses `/usr/bin/zip -j -q -X`). |
| `CrashRecovery.swift` | Scans `NSTemporaryDirectory()` for `livetranslate-<stamp>/` leftover dirs (from crashes / force-quits) and runs MKV+zip+cleanup for each. Idempotent. Runs background at launch. |
| `Paths.swift` | Single source of truth for path layout. `Paths.Outputs` struct: `timestamp`, `workDir` (temp), `zipDestination`, `transcript`, `recording(_:)`, `mergedSubtitle(_:)`, `mkvOutput`, `shippedFiles`. |
| `Log.swift` | Append-only file logger at `/tmp/livetranslate.log`. Truncates on launch if > 5 MB. `line(_:)` prepends `HH:mm:ss.SSS` timestamp. All writes are async on a serial queue. |
| `TTSSpeaker.swift` | `AVSpeechSynthesizer.write(_:toBufferCallback:)` — no local playback. Converts to 24 kHz mono PCM16 LE via per-utterance `AVAudioConverter`. Serial queue, 0.5 s gap between utterances. Max 5 pending; oldest dropped on overflow. `bestVoice(forTargetCode:)` matches primary BCP-47 subtag, ranks Premium > Enhanced > Default. Pre-warms on init. Listener-count gated: `enqueue` is only called by `Pipeline.graduate` when `server.audioListenerCount > 0`. |
| `LiveAudioServer.swift` | Hand-rolled HTTP/1.1 on `NWListener` (port 8765). Routes: `/` → HTML listen page; `/live.wav` → open WAV stream (24 kHz PCM16 LE, `0xFFFFFFFF` chunk size, 200 ms heartbeat task with 50 ms silence = 2400 bytes); `/events` → SSE (200-entry replay, 5 s ping keepalive). `audioListenerCount` and `onAudioListenerCountChanged` drive Pipeline's `ttsActive`. `publishTranscript(jsonLine:)` broadcasts to SSE and buffers for replay. URL resolution prefers private-range IPv4, falls back to `scutil LocalHostName`.local, then `localhost`. |

---

## Key behaviors / non-obvious bits

### One chunk = one sentence

The RMS-based VAD in `WhisperCppTranscriber` already splits the audio at natural
pauses, so each chunk fed to `whisper_full()` is, by construction, one utterance.
Whisper's internal segmentation (it can emit multiple `whisper_segment`s per call)
is joined into a single line before the snapshot leaves the transcriber. The
Pipeline gets one `SessionSentence` per closed chunk, which lands as one `Sentence`
row, which writes one JSONL line.

The transcriber owns sentence segmentation. The Pipeline never splits; it never
edits in place; it only appends.

### Audio-stream timing (SRT/JSONL ↔ WAV alignment)

The accumulator maintains `samplesEverEmitted16k` across all chunks. A chunk's
`chunkStartSample16k` is that counter's value when the chunk opened.
`startSeconds = (chunkStartSample16k + voiceStart) / 16_000`,
`endSeconds = (chunkStartSample16k + voiceEnd) / 16_000`.

`Pipeline` anchors those at `runStartedAt`: `createdAt = runStartedAt +
startSeconds`. The `AudioRecorder` subscribes to the same broadcaster, so
WAV position = audio-stream sample position. SRT cues and JSONL timestamps
are therefore sample-accurate with the `.wav` files.

### Concurrent accumulator + worker (the "second sentence dropped" bug)

Whisper takes 1–3 s to process a chunk. Running the audio pump synchronously with
whisper would lose any utterance during that processing window. The fix: two
structured child tasks via `async let`. The *accumulator* runs continuously,
emitting `ChunkBuffer`s into an unbounded `AsyncStream<ChunkBuffer>`. The *worker*
drains that queue and runs `whisper_full()` serially. Queue is unbounded because
audio rates are too low to create backpressure.

### Whisper hallucination defences

Whisper, trained on captioned video, fabricates phrases like "Thanks for watching!"
or "[Music]" on near-silent or very short input. Four layers of defence:

1. Skip chunks where `voiceStart == nil` (pure-silence max-chunk close).
2. Trim leading/trailing silence off the chunk (±100 ms `voicePaddingSeconds`).
3. Silence-close is gated: only allowed once the chunk total is ≥
   `minWhisperInputSeconds` (1.1 s), so a single "yes" grows past the threshold
   before silence-closing. Max-chunk close fires regardless.
4. Pad short trimmed clips with trailing zeros up to 1.1 s. Whisper silently
   returns zero segments for audio under ~1 s (mel-spectrogram threshold: 100
   frames × 10 ms).

### `initial_prompt` continuity across chunks

`previousChunkTail: [SourceTag: String]` (updated in `processChunk` on success,
keyed by source) stores the last 120 chars of the previous chunk's text and passes
it as `params.initial_prompt` on the next call. Per-source because mic and system
audio are unrelated — mixing the tails would pollute each stream's context.

### Crosstalk suppression (speaker bleed into mic)

The mic always picks up some system audio through the speakers. Mitigation:
`WhisperCppTranscriber` has `lastSystemVoicedAt: Date` (NSLock-protected). The
system accumulator calls `markSystemVoiced()` per voiced buffer. `Pipeline` wires
`DenoisingAudioSource(mic, muteWhen: { whisper?.isSystemRecentlyVoiced() })`.
When system was voiced within 250 ms, `DenoisingAudioSource.denoise()` zeros the
output buffer with `memset` after denoising (RNNoise GRU stays coherent). Both
`AudioRecorder` and the transcriber accumulator see the zeroed buffer.

### Broadcaster pattern (the "won't restart after Stop" problem)

`AsyncStream` is single-consumer. Exposing a stored stream as `buffers` would
break every start after the first — the second consumer iterates an already-drained
stream. Both `MicrophoneSource` and `SystemAudioSource` build a fresh
`AsyncStream` per `buffers` access via `BufferBroadcaster.stream` and fan tap
callbacks to all current subscribers. Rule: `buffers` is a *fresh subscription
factory* — call it per consumer, never cache the result.

### Translation framework quirks

- A `TranslationSession` is **only** obtainable via SwiftUI's `.translationTask`
  modifier. No public programmatic creation. We park the modifier's closure on an
  `AsyncStream<Never>` (`let (parked, holder) = AsyncStream<Never>.makeStream()`
  then `for await _ in parked { }`). Cancellation from SwiftUI wakes the iterator
  and unparks cleanly. **`Task.sleep(nanoseconds: .max)` or similar trips a
  precondition on macOS 15+** — do not use it for parking.
- First time a language pair is used, macOS prompts to download translation models.
  Trigger ahead of time via System Settings → Apple Intelligence & Siri →
  Translation Languages, or open the Translate app.
- `translationConfig` uses `String(pipeline.source.identifier.prefix(2))` — bare
  2-letter code, not full BCP-47 (`"de"` not `"de-DE"`). Apple's `Translation`
  framework requires this form for `Locale.Language(identifier:)`.

### Persisted settings

`source` (`SourceLocale`) and `target` (`TargetLanguage`) stored as JSON-encoded
data in `UserDefaults` under `"pipeline.source"` / `"pipeline.target"`. Default:
`de-DE` / `en`. `compactMode` stored via `@AppStorage("compactMode")`. Mic-on /
system-on are not persisted — both are always captured.

### Permissions

The bundle declares `NSMicrophoneUsageDescription` and
`NSScreenCaptureUsageDescription`. Mic prompts via
`AVCaptureDevice.requestAccess(for: .audio)`. Screen recording prompts when
`SCStream.startCapture()` runs the first time. No speech recognition permission —
whisper.cpp runs locally.

Reset stale grants:
```sh
tccutil reset Microphone local.mtib.livetranslate
tccutil reset ScreenCapture local.mtib.livetranslate
```

Ad-hoc signing produces a fresh cdhash each rebuild → TCC re-prompts. Set
`LIVETRANSLATE_SIGN_IDENTITY` to a self-signed cert name (created via Keychain
Access → Certificate Assistant) and `build.sh` will use it. TCC keys grants on
the cert identity.

### Window behavior

Real macOS app (`LSUIElement = false`). `.floating` level, translucent
(`Color(nsColor: .textBackgroundColor).opacity(0.7)`, no blur), movable from any
point (`isMovableByWindowBackground = true`), `canJoinAllSpaces`,
`fullScreenAuxiliary`, hidden title bar + traffic lights. `fullSizeContentView`
extends content into the title-bar area so there's no dead band.

### Live stream routing and `ttsActive` flag

`ttsActive` = `ttsSpeaker != nil && ttsListenerCount > 0`. The listener count is
tracked by `LiveAudioServer.audioListenerCount` (NSLock-guarded dict of
`NWConnection`s). `onAudioListenerCountChanged` callback hops to `@MainActor` to
update `ttsListenerCount` and call `recomputeTTSActive()`. The UI icon turns
green while `ttsActive`. The `TTSSpeaker.enqueue` call in `graduate()` is gated:
`if !translation.isEmpty, let server = liveAudioServer, server.audioListenerCount > 0`.

### Terminate hook

`App.installTerminateHook` registers for `NSApplication.willTerminateNotification`
once. The handler calls `MainActor.assumeIsolated { pipeline.flushPendingSentences() }`
synchronously (not async Task, which might not complete before exit).
`flushPendingSentences()` calls `archive?.flush()`, `sp.flush()` for each source
pipeline, and `merged.flush()` for each merged subtitle archive — all use
`queue.sync {}` to await their write queues.

---

## Tools / SDKs in use

- `AVAudioEngine`, `AVAudioConverter` — mic capture, sample-rate conversion
- `Accelerate` (`vDSP_measqv`, `vDSP_vsmul`) — AGC RMS measurement + gain multiply
- `ScreenCaptureKit` — system audio capture via `SCStream` (audio-only config)
- `AVSpeechSynthesizer` (`write(_:toBufferCallback:)`) — on-device TTS, no local playback
- `Translation` (`TranslationSession`, `.translationTask`) — Apple on-device translation
- `Network` (`NWListener`, `NWConnection`) — hand-rolled HTTP/1.1 server
- `CoreImage` (`CIQRCodeGenerator`) — QR code in share popover
- SwiftUI — UI, `@Published`, `@AppStorage`, `@ObservedObject`
- `AVAudioFile` — WAV writing (auto Float32→Int16 conversion), duration probing
- `DispatchQueue` — serial queues for disk IO in archive/recorder/subtitle classes
- `NSLock` — serialization of whisper context load, whisper_full, crosstalk state, broadcaster listeners, LiveAudioServer subscriber dicts
- ffmpeg (optional, external, Homebrew) — MKV assembly
- `/usr/bin/zip` — session artifact packaging

Does NOT include: `SFSpeechRecognizer` (removed), `MixedAudioSource` (removed),
`AVCaptureSession` (not used).

---

## Roadmap

- [x] RNNoise denoising per stream (vendored, BSD 3-clause)
- [x] whisper.cpp transcriber (`WhisperCppTranscriber`, current)
- [x] Live LAN stream with HTML listen page + SSE transcript feed + QR share
- [x] Crash recovery (leftover work dirs finalized on next launch)
- [ ] Per-app audio capture (instead of whole-machine) via SCK's filter
- [ ] OpenRouter fallback as an alternative `Translator` impl
- [ ] Global hotkey to start/stop
- [ ] Click-through floating overlay mode
- [ ] Persist transcript history

---

## Build / run / debug commands

```sh
# First-time setup (pre-download model cache, faster subsequent builds)
./dev-setup.sh

# Build (always use LIVETRANSLATE_SIGN_IDENTITY to persist TCC grants)
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh

# Launch (always via `open`, not the binary directly — TCC requires bundle context)
open build/LiveTranslate.app

# Tail the debug log
tail -f /tmp/livetranslate.log

# Kill all instances
pkill -f LiveTranslate

# Force-rebuild whisper.cpp from scratch
./tools/build-whisper.sh --force

# Reset permissions (if TCC gets confused)
tccutil reset Microphone local.mtib.livetranslate
tccutil reset ScreenCapture local.mtib.livetranslate
```

---

## Things that have bitten us already

1. **Running the binary directly** (not via `open`) loses bundle context. TCC
   complains about missing usage-description keys, app crashes on the first
   permission request. Always `open build/LiveTranslate.app`.

2. **Reinstalling the audio tap between recognition sessions** caused recognition
   to silently stop after ~1 minute. Keep the tap permanent across sessions.
   *(Historical: tap-reinstall era, pre-current architecture)*

3. **`requiresOnDeviceRecognition = true`** hard-fails when the on-device model
   isn't installed. *(Historical: Apple Speech era)*

4. **`NSLog` doesn't appear reliably in `log show`** for ad-hoc-signed apps on
   macOS 26. Use `Log.line(_:)` → `/tmp/livetranslate.log`.

5. **Command Line Tools don't ship XCTest or Swift Testing.** No `swift test`
   without full Xcode. Tests deliberately omitted.

6. **Single-consumer `AsyncStream` silently breaks every Start after the first.**
   If an audio source exposed a stored `AsyncStream` as its `buffers` property,
   the second session's pump would iterate an already-drained stream and the
   recognizer would get no audio. Fix: `BufferBroadcaster` creates a fresh stream
   per `buffers` access. Rule: `buffers` is a subscription factory — never cache.

7. **Speaker bleed / stall when mic captures system audio through the speakers.**
   Old design: use system audio source instead of mic. Current design: crosstalk
   suppression gate in `DenoisingAudioSource` (see above).

8. **Index-only snapshot reconciliation** left orphan rows when a recognizer
   revised sentence boundaries. Always handle the "snapshot shrunk" case
   explicitly. *(Historical: Apple Speech era)*

9. **`DispatchSemaphore.wait()` on the MainActor for async SCK setup is an instant
   deadlock.** The original `SystemAudioSource.start()` blocked the main thread
   waiting for SCK's async delegate callback, which needed the main thread to
   deliver — instant freeze. Rule: never block the main thread with a semaphore
   for async work. `AudioSource.start()` is `async throws`.

10. **"Don't drop active-session sentences" was too aggressive.** The original
    `prune` exempted every sentence in the current recognition session — since a
    session can emit many sentences, the list grew forever. Only the last sentence
    needs protection (`protectedIDs()` returns just `sentences.last?.id`).

11. **Caching the `buffers` AsyncStream out of the recognition-cycle while-loop.**
    `AsyncStream` is single-consumer; caching and reusing across sessions means the
    second session's pump iterates a drained stream and the recognizer gets nothing.
    Rule: call `audioSource.buffers` per consumer, per session.

12. **Unstructured `Task { }` children inside a cancellable parent don't inherit
    cancellation.** The old `Pipeline.run()` spawned per-source recognition cycles
    as independent Tasks, then awaited `.value`. Cancelling the parent woke the
    await but the children kept running. A second Stop triggered a duplicate run
    on top. Fix: use `withTaskGroup` so cancellation cascades. Related: don't
    `runTask = nil` inside `stop()` — leave it set so `toggle()` no-ops during
    wind-down.

13. **`CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` with a fixed
    `MemoryLayout<AudioBufferList>.size` only fits ONE AudioBuffer.** SCK delivers
    non-interleaved stereo Float32 — two separate `AudioBuffer`s. The fixed-size
    allocation failed with `kCMSampleBufferError_ArrayTooSmall` on every frame.
    Symptom: `SystemAudio: heartbeat received=X yielded=0 convFails=X`. Fix: use
    `CMSampleBufferCopyPCMDataIntoAudioBufferList(_:at:frameCount:into:)` with
    `AVAudioPCMBuffer.mutableAudioBufferList` — already correctly sized.

14. **Apple Speech serializes recognition tasks per-app** (even with two
    `SFSpeechRecognizer` instances, even with one on-device and one server-side).
    Each restart preempted the other; both fast-failed with "No speech detected".
    The only fix was a single mixed audio stream to one recognizer. *(Historical:
    Apple Speech era — whisper.cpp replaced this entirely)*

15a. **`SFTranscriptionSegment.timestamp` / `.duration` are zero on partial
     results.** Apple only populates them on finals. Pause-based splitting only
     fires at session end (~60 s). *(Historical: Apple Speech era)*

15. **Naive buffer-stream interleaving tanked recognition latency.** Forwarding
    every upstream buffer as it arrived to a mixed stream doubled the
    audio-time-to-wall-time ratio. Fix: mix at the sample level — mic clocks
    the output; system samples pulled from a bounded queue. *(Historical: mixing
    era — per-stream pipelines replaced this entirely)*

16. **Whisper silently drops audio under ~1 s.** Mel-spectrogram threshold: 100
    frames × 10 ms. Symptom: `segments=0` returned in 0.01 s, no error.
    Fix (two layers): (a) accumulator silence-close gate: only allow silence-close
    once chunk total ≥ `minWhisperInputSeconds` (1.1 s); (b) `processChunk` pads
    short trimmed clips with trailing zeros to 1.1 s.

17. **Cancelling `runTask` dropped trailing audio.** Cancellation propagated to
    the accumulator's `for await buf in audio`, which exited without emitting the
    in-flight chunk, and to the worker, which exited without draining the queue.
    Fix: shutdown is driven by ending the audio source (not cancelling the task).
    `AudioSource.stop()` → `BufferBroadcaster.finishAll()` → accumulator's
    for-await exits naturally → final chunk emitted → queue closed → worker drains
    → `run()` exits. Background workers (prune) still need explicit cancellation.

18. **Per-stream pipelines replaced mixing entirely.** Old: sample-sum mic +
    system → one recognizer. Current: independent `SourcePipeline`s, shared whisper
    `ctx` with `NSLock`. No mixing, no attribution loss. The sample-clocking
    principle from lesson #15 is worth keeping as general knowledge.

19. **Two concurrent `whisper_init_from_file_with_params` calls fail on Metal
    contexts.** Both mic and system pipelines reached `ensureContextLoaded()` with
    `ctx == nil` simultaneously. One succeeded; the other failed with "failed to
    load model". Symptom: `Whisper.transcribe[system]: error … failed to load
    model`. Fix: `ctxLoadLock: NSLock` serializes `ensureContextLoaded()`.

20. **Crosstalk: mic picks up system audio through the speakers.** (See
    crosstalk-suppression design decision above.) Caveat: affects only what whisper
    sees; the mic `.wav` previously still had raw bleed because the broadcaster
    was upstream of any mute logic. Current design zeroes the buffer in
    `DenoisingAudioSource.denoise()` after denoising but before `broadcaster.emit`,
    so both the recorder and the transcriber accumulator see muted audio.

21. **`SourcePipeline` must NOT be `@MainActor`.** Making child pipeline classes
    follow `Pipeline`'s `@MainActor` isolation would serialize the per-stream
    accumulators on the main thread — both audio paths and the worker would queue
    behind UI updates. Keep `SourcePipeline`, `WhisperCppTranscriber`,
    `DenoisingAudioSource` as plain classes running on the cooperative pool.
    Only UI-state writes hop back to MainActor via `Task { @MainActor in ... }`.

22. **`tools/build-whisper.sh` skipped header mirroring when the prefix was
    already on disk.** After a branch switch that wiped `Sources/CWhisper/include/`,
    `swift build` failed with `'whisper.h' file not found` even though
    `libwhisper.a` was present. Cause: the `SKIP_LIB_BUILD=1` guard also wrapped
    the `cp …/include/*.h Sources/CWhisper/include/` step. Fix: header mirroring
    runs unconditionally — it's a fast `cp` and ensures the bridge stays in sync.

23. **`Task.sleep(nanoseconds: .max)` (and similar large-duration sleeps) trips
    a precondition on macOS 15+.** The original `.translationTask` parking used
    `Task.sleep` to hold the session alive. This assertion-fails in debug and
    silently misbehaves in release. Fix: park on `AsyncStream<Never>.makeStream()`
    — `for await _ in parked { }` blocks the task indefinitely until the
    continuation's `finish()` is called (in the `defer`).

24. **`TranscriptArchive.encodeLine` must be static for SSE deduplication.** The
    JSONL line written to disk and the SSE event sent to subscribers must be
    bit-identical so the listen page's client-side dedup (`seen` Set keyed by
    `start|end|transcription`) correctly deduplicates replayed events vs. live
    events. If two different code paths produced slightly different JSON
    (e.g., different key order), the dedup would fail and listeners would see
    duplicate rows after reconnect. `encodeLine` is `static` and uses
    `JSONEncoder(.sortedKeys)` so both consumers call the same function and get
    the identical string.

25. **`AVAudioFile.flush()` / close must be awaited before MKV export.** If the
    `AVAudioFile` is not closed before `MKVExporter.export` probes WAV duration
    via `AVAudioFile(forReading:)`, the WAV header's data-chunk length is stale
    (still the value written at `init` time, not updated until close/deinit).
    This made `ffmpeg`'s lavfi `-t` duration calculate as ~0 s, producing a
    near-zero-length video. Fix: `AudioRecorder.flush()` runs `queue.sync {
    self.file = nil }` — setting `file = nil` deinits `AVAudioFile`, which
    finalizes the header. Pipeline calls `sp.flush()` before `MKVExporter.export`.
