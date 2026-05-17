import SwiftUI
import Translation

/// Main UI surface. Two layouts:
///   - Full mode (`!compactMode`): a single-row control bar with primary
///     action, source / target language pickers, translate toggle, and
///     status indicator — followed by the rolling sentence list.
///   - Compact mode: a slim bar (play/stop + language pair + status dot)
///     with the sentence list right below. Designed to float as a small
///     hover overlay over other content.
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
            // Translucent flat color (no blur). Use the system's
            // text-background color (white in light mode, near-black
            // in dark mode) — same theming as `windowBackgroundColor`
            // but with materially more contrast against the primary
            // text. 0.8 opacity keeps the floating overlay translucent
            // over content behind it.
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

    /// Compact bar: primary action, language pair label, per-source
    /// activity icons, expand. Designed to fit a ~280px-wide floating
    /// overlay — icons share the same component as the full bar.
    private var compactBar: some View {
        HStack(spacing: 6) {
            primaryButton(compact: true)
            Text("\(pipeline.source.identifier) → \(pipeline.target.code)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            activityIndicators
            iconButton("chevron.down", help: "Show controls") {
                compactMode = false
            }
        }
    }

    /// Full bar: one clean horizontal row.
    /// Primary on the left, language pair in the middle, per-source
    /// activity icons + compact-mode toggle on the right. The
    /// Start/Stop button is the only "is the pipeline running?" cue —
    /// no separate status dot.
    private var fullBar: some View {
        HStack(spacing: 10) {
            primaryButton(compact: false)

            sourcePicker
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            targetPicker

            Spacer(minLength: 6)

            activityIndicators
            iconButton("chevron.up", help: "Compact view") {
                compactMode = true
            }
        }
    }

    /// Per-source busy state: a mic icon when a chunk is currently
    /// being captured (voiced) and a "pen on paper" icon when whisper
    /// is running on a chunk. Each tinted with the source's color
    /// (mic = warm, system = cool). Up to four icons can be visible
    /// when both streams are simultaneously capturing + transcribing.
    private var activityIndicators: some View {
        HStack(spacing: 3) {
            indicatorIcon("mic.fill", source: .mic, active: pipeline.capturingVoice[.mic] ?? false, help: "Capturing mic chunk")
            indicatorIcon("doc.text.fill", source: .mic, active: pipeline.transcribingChunk[.mic] ?? false, help: "Transcribing mic chunk")
            indicatorIcon("mic.fill", source: .system, active: pipeline.capturingVoice[.system] ?? false, help: "Capturing system chunk")
            indicatorIcon("doc.text.fill", source: .system, active: pipeline.transcribingChunk[.system] ?? false, help: "Transcribing system chunk")
        }
    }

    /// One activity icon — full-saturation source tint when `active`,
    /// standard secondary text color when idle (theme-aware, so the
    /// off state reads correctly in both light and dark mode). The
    /// persistent visible state preserves row layout when activities
    /// toggle.
    private func indicatorIcon(_ systemName: String, source: SourceTag, active: Bool, help: String) -> some View {
        let tint: Color = source == .mic ? .red : .blue
        let style: AnyShapeStyle = active
            ? AnyShapeStyle(tint)
            : AnyShapeStyle(.secondary)
        return Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(style)
            .frame(width: 14, height: 14)
            .help(help)
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

    /// Auto-scrolling list of sentences. The newest is at the bottom and
    /// gets full opacity; older ones fade to 0.8.
    private func sentenceList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(Array(pipeline.sentences.enumerated()), id: \.element.id) { idx, sentence in
                        SentenceRow(
                            sentence: sentence,
                            isMostRecent: idx == pipeline.sentences.count - 1,
                            compact: compact
                        )
                        .id(sentence.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: compact ? 50 : 140)
            // No scrollbar — the list is short by design (capped at
            // maxSentenceCount) and the indicator just adds visual noise.
            // The window scrolls anyway when content overflows; we just
            // don't show the thumb.
            .scrollIndicators(.hidden)
            .onChange(of: pipeline.sentences.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            .onChange(of: pipeline.sentences.last?.text) { _, _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
            .onChange(of: pipeline.sentences.last?.translation) { _, _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }
}

/// One sentence row: translation as the primary line, source text as a
/// caption underneath. Most-recent sentence is full opacity; older rows
/// fade to 0.8. In compact mode the source caption is hidden for older
/// rows to keep the overlay slim.
private struct SentenceRow: View {
    let sentence: Sentence
    let isMostRecent: Bool
    let compact: Bool

    var body: some View {
        let opacity: Double = isMostRecent ? 1.0 : 0.8
        // Subtle source tint via `colorMultiply`: shifts text slightly
        // toward red (mic) or blue (system). ~85% on the off axes — a
        // gentle warm / cool cast, much subtler than v2's .65 (which
        // made the translated lines feel dim). The translation stays
        // bright because it's `.primary` × this near-white multiplier.
        let tintMultiplier: Color = sentence.source == .mic
            ? Color(red: 1.0, green: 0.85, blue: 0.85)
            : Color(red: 0.85, green: 0.90, blue: 1.0)

        VStack(alignment: .leading, spacing: 1) {
            Text(sentence.translation.isEmpty ? sentence.text : sentence.translation)
                .font(compact ? .callout : .body)
                .foregroundStyle(.primary.opacity(opacity))
                .colorMultiply(tintMultiplier)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if !compact, !sentence.translation.isEmpty {
                Text(sentence.text)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(opacity * 0.85))
                    .colorMultiply(tintMultiplier)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
