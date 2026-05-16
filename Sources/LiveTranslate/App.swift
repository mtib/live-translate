import SwiftUI

@main
struct LiveTranslateApp: App {
    @StateObject private var pipeline = Pipeline()

    init() {
        Log.startup()  // truncates the log if it's grown past the cap
    }

    var body: some Scene {
        Window("LiveTranslate", id: "main") {
            TranscriptView(pipeline: pipeline)
                .frame(minWidth: 260, minHeight: 80)
                .background(WindowAccessor { window in
                    configure(window)
                })
                .onAppear { installTerminateHook(pipeline: pipeline) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 480)
    }

    /// Registers (once) for `NSApplication.willTerminateNotification` so
    /// any sentences still visible in the rolling list get archived to
    /// the JSONL file before the process exits. Without this, Cmd+Q
    /// would drop everything that hadn't aged into the prune path yet.
    private func installTerminateHook(pipeline: Pipeline) {
        if Self.terminateHookInstalled { return }
        Self.terminateHookInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // `queue: .main` guarantees this runs on the main thread, so
            // we can safely assume MainActor isolation. A `Task { @MainActor }`
            // would be async and might not finish before the process exits.
            MainActor.assumeIsolated { pipeline.flushPendingSentences() }
        }
    }
    private static var terminateHookInstalled = false

    /// Tweaks the host NSWindow once SwiftUI hands it to us: translucent,
    /// movable from any point in the window, floats above other apps,
    /// stays across Spaces.
    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

/// Bridge to grab the underlying NSWindow so we can apply non-SwiftUI
/// properties (translucency, floating level, click-through behaviour).
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let w = view?.window { onWindow(w) }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
