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
            VisualEffectBackground().ignoresSafeArea()
            content
        }
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

    /// Compact bar: status dot, primary action, language pair label, expand.
    /// Designed to fit a ~280px-wide floating overlay.
    private var compactBar: some View {
        HStack(spacing: 8) {
            statusDot
            primaryButton(compact: true)
            Text("\(pipeline.source.identifier) → \(pipeline.target.code)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            iconButton("chevron.down", help: "Show controls") {
                compactMode = false
            }
        }
    }

    /// Full bar: one clean horizontal row with everything inline.
    /// Primary on the left, language config in the middle, secondary
    /// controls on the right. No labels — icons + tooltips are enough.
    private var fullBar: some View {
        HStack(spacing: 10) {
            primaryButton(compact: false)

            sourcePicker
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            targetPicker

            Toggle("", isOn: $pipeline.translateEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(pipeline.translateEnabled ? "Translation on" : "Translation off")

            Spacer(minLength: 6)

            statusDot
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
                Text(src.identifier).tag(src)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 95)
        .disabled(pipeline.isRunning)
        .controlSize(.small)
    }

    private var targetPicker: some View {
        Picker("", selection: $pipeline.target) {
            ForEach(pipeline.availableTargets) { lang in
                Text(lang.name).tag(lang)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 130)
        .disabled(!pipeline.translateEnabled)
        .controlSize(.small)
    }

    /// 8x8 colored dot reflecting `PipelineStatus`. Hover for the full
    /// status text — keeps the UI quiet in normal use.
    private var statusDot: some View {
        let (color, label) = statusVisual(pipeline.status)
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(color.opacity(0.4), lineWidth: 3)
                    .scaleEffect(pipeline.isRunning ? 1.5 : 1.0)
                    .opacity(pipeline.isRunning ? 0.6 : 0)
                    .animation(
                        pipeline.isRunning
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: pipeline.isRunning
                    )
            )
            .help(label)
    }

    private func statusVisual(_ s: PipelineStatus) -> (Color, String) {
        switch s {
        case .idle: return (.secondary, "Idle")
        case .requestingPermissions: return (.orange, "Requesting permission…")
        case .starting: return (.yellow, "Starting…")
        case .running: return (.green, "Listening")
        case .stopped(let reason): return (.red, "Stopped: \(reason)")
        }
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
                    if pipeline.sentences.isEmpty {
                        Text("…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 2)
                    }
                    ForEach(Array(pipeline.sentences.enumerated()), id: \.element.id) { idx, sentence in
                        SentenceRow(
                            sentence: sentence,
                            isMostRecent: idx == pipeline.sentences.count - 1,
                            translateEnabled: pipeline.translateEnabled,
                            compact: compact
                        )
                        .id(sentence.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: compact ? 50 : 140)
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

/// One sentence row. Most-recent is full opacity; older fade to 0.8.
/// In compact mode the source-language line is hidden for non-current
/// sentences to save vertical space.
private struct SentenceRow: View {
    let sentence: Sentence
    let isMostRecent: Bool
    let translateEnabled: Bool
    let compact: Bool

    var body: some View {
        let opacity: Double = isMostRecent ? 1.0 : 0.8

        VStack(alignment: .leading, spacing: 1) {
            if translateEnabled {
                Text(sentence.translation.isEmpty ? "…" : sentence.translation)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.primary.opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                // Source caption is shown always in full mode, only for
                // the live row in compact mode.
                if !compact || isMostRecent {
                    Text(sentence.text)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(opacity * 0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text(sentence.text)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.primary.opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
