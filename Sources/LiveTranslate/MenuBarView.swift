import SwiftUI

/// Compact transcript UI shown inside the MenuBarExtra `.window` popover.
/// Mirrors the compact bar layout from `TranscriptView` and reuses
/// `SentenceRow`, `InflightRow`, and `StreamShareView` for identical rendering.
struct MenuBarView: View {
    @ObservedObject var pipeline: Pipeline
    @Binding var isWindowVisible: Bool
    let mainWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactBar
            sentenceList
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 340)
    }

    // MARK: - Bar

    private var compactBar: some View {
        HStack(spacing: 6) {
            primaryButton
            Text("\(pipeline.source.identifier) → \(pipeline.target.code)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            streamShareButton
            overlayToggleButton
        }
    }

    private var primaryButton: some View {
        let finalizing = pipeline.status.isFinalizing
        return Button {
            pipeline.toggle()
        } label: {
            if finalizing {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Image(systemName: pipeline.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(finalizing ? .secondary : (pipeline.isRunning ? .red : .accentColor))
        .disabled(finalizing)
        .keyboardShortcut(.return, modifiers: [])
    }

    @State private var streamShareShown = false
    @ViewBuilder
    private var streamShareButton: some View {
        if let url = pipeline.liveStreamURL {
            Button { streamShareShown.toggle() } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        pipeline.ttsActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
                    )
                    .animation(.easeInOut(duration: 0.25), value: pipeline.ttsActive)
            }
            .buttonStyle(.plain)
            .help(pipeline.ttsActive ? "Live audio stream — listener connected" : "Live translated-audio stream")
            .popover(isPresented: $streamShareShown, arrowEdge: .bottom) {
                StreamShareView(url: url).padding(16).frame(width: 240)
            }
        }
    }

    private var overlayToggleButton: some View {
        Button {
            if isWindowVisible {
                mainWindow?.orderOut(nil)
            } else {
                mainWindow?.orderFrontRegardless()
            }
            isWindowVisible.toggle()
        } label: {
            Image(systemName: isWindowVisible ? "pip.exit" : "pip.enter")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isWindowVisible ? "Hide floating overlay" : "Show floating overlay")
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }

    // MARK: - Sentence list

    private var sentenceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pipeline.sentences) { sentence in
                        SentenceRow(sentence: sentence, compact: true)
                            .id(sentence.id)
                            .transition(.opacity)
                    }
                    ForEach(pipeline.inflightChunks) { chunk in
                        InflightRow(chunk: chunk, compact: true)
                            .id(chunk.id)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 2)
                .animation(.easeInOut(duration: 0.18), value: pipeline.sentences.map(\.id))
                .animation(.easeInOut(duration: 0.18), value: pipeline.inflightChunks)
            }
            // ~6 compact rows: callout font (~16pt) + 6pt spacing = ~22pt/row
            .frame(minHeight: 50, maxHeight: 132)
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
