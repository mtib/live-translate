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
            // Translucent flat color (no blur). Adapts to light/dark mode
            // via the system window background. Lower opacity = more of
            // the content behind the window shows through.
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.8)
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

    /// Full bar: one clean horizontal row.
    /// Primary on the left, language pair in the middle, indicator and
    /// compact-mode toggle on the right. No labels — the arrow between
    /// the pickers tells you which way translation goes.
    private var fullBar: some View {
        HStack(spacing: 10) {
            primaryButton(compact: false)

            sourcePicker
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            targetPicker

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
                Text(src.displayName).tag(src)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 170)
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
        .frame(maxWidth: 140)
        .controlSize(.small)
    }

    /// 8×8 colored dot reflecting `PipelineStatus`. Pulses while live;
    /// hover for the full status text.
    private var statusDot: some View {
        let color = pipeline.status.dotColor
        let live = pipeline.status.isLive
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 3)
                    .scaleEffect(live ? 1.5 : 1.0)
                    .opacity(live ? 0.6 : 0)
                    .animation(
                        live ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                        value: live
                    )
            )
            .help(pipeline.status.description)
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

/// Status-dot color mapping. Lives here (not on the enum itself) because
/// `Color` is a SwiftUI type and Types.swift is import-free of SwiftUI.
private extension PipelineStatus {
    var dotColor: Color {
        switch self {
        case .idle: return .secondary
        case .requestingPermissions: return .orange
        case .starting: return .yellow
        case .running: return .green
        case .stopped: return .red
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

        VStack(alignment: .leading, spacing: 1) {
            Text(sentence.translation.isEmpty ? sentence.text : sentence.translation)
                .font(compact ? .callout : .body)
                .foregroundStyle(.primary.opacity(opacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            // Source caption only in full mode. Compact mode shows
            // translations only — the source text would clutter the
            // overlay and the user can switch out of compact if they
            // want to verify.
            if !compact, !sentence.translation.isEmpty {
                Text(sentence.text)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(opacity * 0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
