import SwiftUI
import Translation

/// The main UI surface. Layout-wise it's a single column of:
///
///     [ control bar — Start/Stop, language pickers, input toggles ]
///     [ status line                                              ]
///     [ Sentence list (rolling, recent rows full opacity)        ]
///
/// Compact mode hides the controls and just shows the sentence list,
/// for a slim floating overlay. State is persisted via `@AppStorage`.
struct TranscriptView: View {
    @ObservedObject var pipeline: Pipeline

    /// Compact (hover) mode: hides controls, shows just sentences.
    @AppStorage("compactMode") private var compactMode: Bool = false

    /// `.translationTask` configuration. Bare language codes are
    /// required (e.g. "de" not "de-DE"), so we strip the region from
    /// the source.
    private var translationConfig: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: String(pipeline.source.identifier.prefix(2))),
            target: Locale.Language(identifier: pipeline.target.code)
        )
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: compactMode ? 6 : 12) {
                if compactMode {
                    compactBar
                    sentenceList
                } else {
                    controlBar
                    statusLine
                    Divider()
                    sentenceList
                }
            }
            .padding(compactMode ? 10 : 16)
        }
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

    // MARK: - Sentence list

    private var sentenceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if pipeline.sentences.isEmpty {
                        Text("…")
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(pipeline.sentences.enumerated()), id: \.element.id) { idx, sentence in
                        SentenceRow(
                            sentence: sentence,
                            isMostRecent: idx == pipeline.sentences.count - 1,
                            translateEnabled: pipeline.translateEnabled
                        )
                        .id(sentence.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: compactMode ? 50 : 120)
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

    // MARK: - Bars

    private var compactBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pipeline.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Button(pipeline.isRunning ? "■" : "▶") { pipeline.toggle() }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
            Text("\(pipeline.source.identifier) → \(pipeline.target.code)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button { compactMode = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .help("Show full controls")
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(pipeline.isRunning ? "Stop" : "Start") { pipeline.toggle() }
                    .keyboardShortcut(.return)

                Picker("From", selection: $pipeline.source) {
                    ForEach(pipeline.availableSources) { src in
                        Text(src.identifier).tag(src)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
                .disabled(pipeline.isRunning)

                Toggle("Translate", isOn: $pipeline.translateEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Picker("To", selection: $pipeline.target) {
                    ForEach(pipeline.availableTargets) { lang in
                        Text(lang.name).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .disabled(!pipeline.translateEnabled)

                Spacer()
                Button { compactMode = true } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .help("Compact view")
            }
            // Second row: input toggles. Both can be on at once; when both
            // are enabled, audio from the two is mixed before recognition
            // (see Pipeline's MixedAudioSource).
            HStack(spacing: 10) {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $pipeline.micEnabled) {
                    Label("Mic", systemImage: "mic.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(pipeline.isRunning)

                Toggle(isOn: $pipeline.systemEnabled) {
                    Label("System", systemImage: "speaker.wave.2.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(pipeline.isRunning)

                Spacer()
            }
        }
    }

    private var statusLine: some View {
        Text(pipeline.status.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// One sentence row. Most-recent gets full opacity; older sentences fade.
/// No source tinting — the Pipeline mixes sources into one stream before
/// recognition, so per-row attribution would be meaningless.
private struct SentenceRow: View {
    let sentence: Sentence
    let isMostRecent: Bool
    let translateEnabled: Bool

    var body: some View {
        let opacity: Double = isMostRecent ? 1.0 : 0.45

        VStack(alignment: .leading, spacing: 2) {
            if translateEnabled {
                Text(sentence.translation.isEmpty ? "…" : sentence.translation)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(sentence.text)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(sentence.text)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
    }
}
