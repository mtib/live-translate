import SwiftUI
import Translation

/// The main UI surface. Layout-wise it's a single column of:
///
///     [ control bar — Start/Stop, language pickers, source, Quit ]
///     [ status line                                              ]
///     [ Sentence list (rolling, recent rows full opacity)        ]
///     [ Clear bar                                                ]
///
/// Compact mode hides everything except the sentence list, for a slim
/// floating overlay. State is persisted via `@AppStorage`.
struct TranscriptView: View {
    @ObservedObject var pipeline: Pipeline

    /// Compact (hover) mode: hides controls, just shows the sentence list.
    @AppStorage("compactMode") private var compactMode: Bool = false

    /// Configuration for `.translationTask`. Bare language codes are required
    /// (e.g. "de" not "de-DE"), so we strip the region from the source.
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
        // Hold the translation session for the lifetime of this configuration;
        // see TranslationSession.Configuration note above.
        .translationTask(translationConfig) { session in
            (pipeline.translator as? AppleTranslator)?.setSession(session)
            do {
                try await session.prepareTranslation()
                Log.line("Translation prepared")
            } catch {
                Log.line("prepareTranslation failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: .max)
            (pipeline.translator as? AppleTranslator)?.setSession(nil)
        }
    }

    // MARK: - Sentence list

    /// The rolling sentence list. Each row shows source text on top and
    /// translation (if any) below. Older sentences fade out. The list is
    /// pinned to the bottom — newest at the bottom edge.
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
            // Second row: input source toggles. Both can be on at once;
            // sentences from each get distinct color tinting in the list.
            HStack(spacing: 10) {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $pipeline.micEnabled) {
                    Label("Mic", systemImage: "mic.fill")
                        .foregroundStyle(SentenceKind.microphone.tint)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(pipeline.isRunning)

                Toggle(isOn: $pipeline.systemEnabled) {
                    Label("System", systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(SentenceKind.systemAudio.tint)
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
/// A thin tinted strip on the leading edge encodes which audio source the
/// sentence came from (green for mic, blue for system audio) — subtle but
/// always visible so dual-source conversations stay readable.
private struct SentenceRow: View {
    let sentence: Sentence
    let isMostRecent: Bool
    let translateEnabled: Bool

    var body: some View {
        let opacity: Double = isMostRecent ? 1.0 : 0.45
        let tint = sentence.kind.tint

        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint.opacity(isMostRecent ? 0.9 : 0.5))
                .frame(width: 3)
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
        }
        .padding(.vertical, 1)
        // Subtle background wash so dual-source rows read at a glance even
        // without staring at the leading strip.
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(isMostRecent ? 0.10 : 0.05))
        )
    }
}

extension SentenceKind {
    /// Color used to tint rows from this source.
    /// - mic: green-ish (your voice)
    /// - systemAudio: blue-ish (everything else playing on the machine)
    var tint: Color {
        switch self {
        case .microphone: return .green
        case .systemAudio: return .blue
        }
    }
}
