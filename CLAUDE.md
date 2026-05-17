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

## How it's built

- **No `.xcodeproj`.** Pure SwiftPM. Built with Command Line Tools only
  (`/Library/Developer/CommandLineTools`). No Xcode required.
- `swift-tools-version: 6.0`, but the executable target is pinned to
  `.swiftLanguageMode(.v5)` because the Translation / Speech APIs are awkward
  under Swift 6 strict concurrency.
- `./build.sh` compiles via `swift build -c release` and wraps the binary
  into `build/LiveTranslate.app/` with `Info.plist` + ad-hoc codesign.
  **Always launch via `open build/LiveTranslate.app`** — never run the binary
  directly. TCC associates permission grants with the bundle, not the
  executable path; direct exec leads to the system thinking
  `NSSpeechRecognitionUsageDescription` is missing.

## Architecture

```
   Mic ──buffers──▶ Transcriber ──SessionSnapshot──┐
                                                    ├─▶ Pipeline.ingest(_, kind)
   System audio ─▶ Transcriber ──SessionSnapshot──┘
                                                    │
                                                    ▼
                                            @Published sentences: [Sentence]
                                                    │       ▲
                                                    │       │ writes translation back
                                                    ▼       │
                                            Translator (per-sentence, cached)
```

Each stage is a protocol so it can be swapped (whisper.cpp, OpenRouter,
ScreenCaptureKit) without touching `Pipeline`.

### Key design decisions

- **Always mix mic + system.** The app no longer exposes input toggles —
  mic and system audio are always both captured and sample-summed by
  `MixedAudioSource` before the single SFSpeechRecognizer sees them.
  Apple Speech serializes recognition tasks per-app, so two concurrent
  recognizers can't coexist; mixing into one stream is the workaround.
  Both audio sources standardize on 16 kHz mono Float32 (SFSpeech's
  native format) so the mixed stream is format-consistent and the per-
  sample sum is meaningful.
- **Transcribers emit sentence snapshots, not raw text.** A `SessionSnapshot`
  carries `[SessionSentence]` already split. The Pipeline reconciles each
  snapshot against its own array by position — this handles "new sentence
  appeared", "sentence text grew", and "recognizer revised away a sentence
  boundary" uniformly. Splitting lives in the transcriber because it's
  backend-specific.
- **Translation cache.** `Pipeline.translationCache: [String: String]`
  keyed by source text. Identical strings across sessions reuse the
  cached translation. LRU-ish eviction at 200 entries.
- **Per-sentence, eager translation.** Translation worker sends any
  sentence whose text differs from `lastTranslatedSource`. The cache
  keeps duplicate strings free. `translationStabilityDelay` is `0` —
  partials translate as soon as their text changes. (The variable
  stays in code as a tunable in case the recognizer ever floods us.)
- **Pruning.** Non-protected sentences whose `lastModified` is older
  than **60 s** get dropped once per second. Hard cap at **8** retained.
  "Protected" means: the most-recent sentence overall, and the live
  (last-active) sentence. Earlier session-active sentences are eligible
  to drop; if the recognizer's next snapshot still references them,
  ingest finds no matching UUID and silently skips, so the drop sticks.
- **Per-run output files.** Each Start opens **two** paired files under
  one app-private root, sharing a `YYYY-MM-DD_HH-MM-SS` timestamp stem:

  ```
  ~/Documents/LiveTranslate/
      transcripts/<stamp>.jsonl   ← every sentence ever dropped (prune or max-count)
      recordings/<stamp>.wav      ← the mixed mic+system audio that fed the recognizer
  ```

  The transcript line shape:
  ```json
  {"time":"2026-05-16T22:13:07.123Z","transcription":"…","translation":"…"}
  ```
  Keys sorted for grep/diff stability, ISO-8601 timestamps,
  `transcription` and `translation` always present (translation may be
  empty if the recognizer hadn't translated it yet).

  The `.wav` is 16 kHz mono signed-16-bit linear PCM (AVAudioFile auto-
  converts our Float32 buffers on the write path). One sample = exactly
  what the recognizer heard, so audio and transcript line up. Paths
  are centralised in `Paths.swift`.

### Files

| File | Role |
|---|---|
| `App.swift` | `@main` entry. SwiftUI `Window` scene. Configures the NSWindow for floating / translucent / movable-from-background behavior. |
| `TranscriptView.swift` | The whole UI. Renders one `SentenceRow` per sentence, with opacity fade for older rows. Hosts `.translationTask` (the only way to get a `TranslationSession`). Background is a flat translucent color — no blur. |
| `Pipeline.swift` | `@MainActor ObservableObject` orchestrator. Owns the published `sentences` array. Runs **one** recognition cycle on a `MixedAudioSource` that sample-sums mic + system. Translation + prune workers run alongside. Persists user settings via UserDefaults. |
| `BufferBroadcaster.swift` | Helper that fans audio buffers out to any number of subscribed `AsyncStream`s — used by all three `AudioSource` implementations to avoid duplicating the broadcaster pattern. |
| `Types.swift` | `SourceLocale`, `TargetLanguage`, `Sentence`, `PipelineStatus`, `SessionSentence` / `SessionSnapshot`. Protocols: `AudioSource`, `Transcriber`, `Translator`. |
| `MicrophoneSource.swift` | `AVAudioEngine` mic capture. Converts to 16 kHz mono Float32 so output matches `SystemAudioSource` (required by `MixedAudioSource`). Broadcaster pattern. |
| `SystemAudioSource.swift` | `ScreenCaptureKit`-based system audio capture. Converts `CMSampleBuffer` → 16 kHz mono Float32 `AVAudioPCMBuffer`. |
| `MixedAudioSource.swift` | Combines two `AudioSource`s by **sample-summing** at mic's cadence. Mic clocks the output; system samples are pulled from a small queue and added per-sample. Keeps audio-time : wall-time at 1:1 so the recognizer doesn't lag. |
| `AppleSpeechTranscriber.swift` | Apple `Speech` framework. Owns the sentence splitter (`splitIntoSentences`). |
| `AppleTranslator.swift` | Holds a `TranslationSession` that the View injects via `Pipeline.installTranslationSession(_:)`. |
| `TranscriptArchive.swift` | One-per-run JSONL archive. Takes its file URL; doesn't know about layout. |
| `AudioRecorder.swift` | One-per-run `.wav` writer fed by a parallel consumer of the active source's broadcaster. 16 kHz mono Int16. |
| `Paths.swift` | Single source of truth for `~/Documents/LiveTranslate/{transcripts,recordings}/<stamp>.…`. |
| `Log.swift` | Append-only file logger at `/tmp/livetranslate.log`. Truncates on launch if > 5 MB. |

## Key behaviors / non-obvious bits

### Recognition cycle (the "~1 minute" problem)
Apple's on-device `SFSpeechRecognizer` ends each session after ~60 seconds,
either with `isFinal = true` or `kAFAssistantErrorDomain 216`. Each
per-source recognition cycle catches that boundary, marks all current
session sentences final, and starts a new session.

**The audio engine is kept running continuously** across recognition
restarts — only the `SFSpeechAudioBufferRecognitionRequest` and task are
cycled. Tearing down / restarting the audio engine between sessions caused
the original "stops after some time" bug.

### Broadcaster pattern (the "won't restart after Stop" problem)
`AsyncStream` is single-consumer. The previous design exposed a single
stored AsyncStream as `buffers` — when a second `transcribe(...)` call
tried to read from it after the first iterator was gone, it got no data
and the recognizer hit "No speech detected" within ~50ms. Both
`MicrophoneSource` and `SystemAudioSource` now build a fresh AsyncStream
per `buffers` access and fan tap callbacks out to all current subscribers.

### Snapshot diff (the "earlier row keeps getting more text" problem)
The recognizer can revise its own sentence boundaries — what was two
sentences at t=0 might be one at t=1. The previous design mapped parsed
sentences by index and left orphan rows when the count shrank. The new
`SessionSnapshot` API plus `Pipeline.ingest` truncate orphans:
- snapshot grew → append new Sentence with fresh UUID
- snapshot same size → update text/isFinal in place (UUID preserved)
- snapshot shrank → drop the now-missing sentences

### Fast-fail bail
If a session ends in less than 1 second, that counts as a "fast fail"
(usually means the language model isn't installed or the audio source is
silent). After **6** in a row the Pipeline gives up with a
`.stopped(reason:)` message pointing at System Settings.

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
- `NSSpeechRecognitionUsageDescription`
- `NSScreenCaptureUsageDescription` (for system audio via SCK)

Mic prompts via `AVCaptureDevice.requestAccess`. Speech prompts via
`SFSpeechRecognizer.requestAuthorization`. Screen recording prompts when
`SCStream.startCapture()` runs the first time.

Reset stale grants with:
```sh
tccutil reset Microphone local.mtib.livetranslate
tccutil reset SpeechRecognition local.mtib.livetranslate
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
- [ ] whisper.cpp backend as an alternative `Transcriber` impl
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
