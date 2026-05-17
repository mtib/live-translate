import SwiftUI
import Translation

/// Main UI surface. Two layouts:
///   - Full mode (`!compactMode`): one-row control bar (Start/Stop,
///     source / target language pickers, compact toggle) followed by
///     the rolling sentence list.
///   - Compact mode: a slim bar (play/stop + language pair + expand)
///     with the sentence list directly below. Designed to float as
///     a small hover overlay over other content.
///
/// The sentence list shows completed `Sentence` rows followed by any
/// `InflightChunk` rows currently in flight (listening / transcribing /
/// translating). When a chunk graduates, its inflight row is replaced
/// by the matching sentence with the same UUID, so SwiftUI animates
/// the transition smoothly.
///
/// The view persists its compact-mode preference via `@AppStorage`. All
/// other settings live in `Pipeline` (which persists them via UserDefaults).
struct TranscriptView: View {
    @ObservedObject var pipeline: Pipeline
    @AppStorage("compactMode") private var compactMode: Bool = false

    private var translationConfig: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: String(pipeline.source.identifier.prefix(2))),
            target: Locale.Language(identifier: pipeline.target.code)
        )
    }

    var body: some View {
        ZStack {
            // Translucent flat color (no blur). Theme-aware via
            // `NSColor.textBackgroundColor` (white in light, near-black
            // in dark) — more contrast against the primary text than
            // `windowBackgroundColor` would give. 0.7 opacity keeps
            // the overlay see-through over content behind it.
            Color(nsColor: .textBackgroundColor)
                .opacity(0.7)
                .ignoresSafeArea()
            content
        }
        // Extend into the (now-hidden) title-bar area so we don't leave
        // a dead band above our controls.
        .ignoresSafeArea()
        // Park the translation session for the lifetime of this config.
        .translationTask(translationConfig) { session in
            pipeline.installTranslationSession(session)
            do {
                try await session.prepareTranslation()
                Log.line("Translation prepared")
            } catch {
                Log.line("prepareTranslation failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: .max)
            pipeline.installTranslationSession(nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        if compactMode {
            VStack(alignment: .leading, spacing: 6) {
                compactBar
                sentenceList(compact: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                fullBar
                if case .stopped(let reason) = pipeline.status {
                    errorBanner(reason)
                }
                sentenceList(compact: false)
            }
            .padding(14)
        }
    }

    // MARK: - Bars

    /// Compact bar: primary action, language pair label, expand.
    /// In-flight activity is shown in the sentence list itself (one
    /// row per active chunk), so the bar stays minimal.
    private var compactBar: some View {
        HStack(spacing: 6) {
            primaryButton(compact: true)
            Text("\(pipeline.source.identifier) → \(pipeline.target.code)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            iconButton("chevron.down", help: "Show controls") {
                compactMode = false
            }
        }
    }

    /// Full bar: primary action, source/target pickers, compact toggle.
    /// In-flight chunk state is visible in the sentence list rows;
    /// the Start/Stop button color is the only "is the pipeline
    /// running?" cue.
    private var fullBar: some View {
        HStack(spacing: 10) {
            primaryButton(compact: false)
            sourcePicker
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            targetPicker
            Spacer(minLength: 6)
            iconButton("chevron.up", help: "Compact view") {
                compactMode = true
            }
        }
    }

    /// Inline banner shown only on `.stopped(reason:)`. Suppressed for
    /// idle / running so the UI stays quiet in the common case.
    private func errorBanner(_ reason: String) -> some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.orange.opacity(0.12))
            )
    }

    // MARK: - Building blocks

    /// Start/Stop. Stays compact in compact-mode (icon-only) and shows a
    /// label in full mode.
    private func primaryButton(compact: Bool) -> some View {
        Button {
            pipeline.toggle()
        } label: {
            if compact {
                Image(systemName: pipeline.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: pipeline.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(pipeline.isRunning ? "Stop" : "Start")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .tint(pipeline.isRunning ? .red : .accentColor)
        .keyboardShortcut(.return, modifiers: [])
    }

    private var sourcePicker: some View {
        Picker("", selection: $pipeline.source) {
            ForEach(pipeline.availableSources) { src in
                Text(src.displayName).tag(src)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 170)
        .controlSize(.small)
        // Enabled even while running: the Pipeline will tear the
        // current run down (flushing transcripts/audio) and start a
        // fresh one with the new language.
    }

    private var targetPicker: some View {
        Picker("", selection: $pipeline.target) {
            ForEach(pipeline.availableTargets) { lang in
                Text(lang.name).tag(lang)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 140)
        .controlSize(.small)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Sentence list

    /// Auto-scrolling list. Completed sentences first, then in-flight
    /// chunks at the bottom (each showing its current state with the
    /// source icon prefix). Rows fade/slide in with `.transition` and
    /// the list animates on changes so additions / state flips /
    /// removals all look smooth instead of popping.
    private func sentenceList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(pipeline.sentences) { sentence in
                        SentenceRow(sentence: sentence, compact: compact)
                            .id(sentence.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    ForEach(pipeline.inflightChunks) { chunk in
                        InflightRow(chunk: chunk, compact: compact)
                            .id(chunk.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 2)
                .animation(.easeInOut(duration: 0.18), value: pipeline.sentences.map(\.id))
                .animation(.easeInOut(duration: 0.18), value: pipeline.inflightChunks)
            }
            .frame(minHeight: compact ? 50 : 140)
            .scrollIndicators(.hidden)
            .onChange(of: pipeline.sentences.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            .onChange(of: pipeline.inflightChunks.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
    }
}

/// One completed-sentence row. Source icon (mic/speaker) on the left
/// keeps the layout aligned with in-flight rows; translation is the
/// primary line; source-text caption sits beneath it in full mode.
/// No tints — everything uses standard text colors.
private struct SentenceRow: View {
    let sentence: Sentence
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: sentence.source.iconSystemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(sentence.translation.isEmpty ? sentence.text : sentence.translation)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if !compact, !sentence.translation.isEmpty {
                    Text(sentence.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// In-flight chunk row — reserves UI space the moment a chunk's voice
/// is detected. Icon on the left is the source (mic or speaker, same
/// as `SentenceRow` so the layout stays stable through graduation).
/// The body is an italic state word ("listening", "transcribing",
/// "translating") and — once whisper has returned text — the
/// transcription itself, ready for the translation to land.
private struct InflightRow: View {
    let chunk: InflightChunk
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: chunk.source.iconSystemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(stateLabel)
                    .font(compact ? .callout : .body)
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Once whisper has returned text, show it in the
                // caption slot while the italic primary line shifts
                // to "translating" — same layout as a graduated row.
                if !compact, case .translating(let text) = chunk.state {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var stateLabel: String {
        switch chunk.state {
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .translating: return "translating"
        }
    }
}
