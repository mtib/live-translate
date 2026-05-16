import SwiftUI

@main
struct TranscrybeDIYApp: App {
    @StateObject private var pipeline = Pipeline()

    var body: some Scene {
        Window("Transcrybe", id: "main") {
            TranscriptView(pipeline: pipeline)
                .frame(minWidth: 260, minHeight: 80)
                .background(WindowAccessor { window in
                    configure(window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 480)
    }

    /// Tweaks the host NSWindow once SwiftUI hands it to us: vibrant,
    /// movable from any point in the window, floats above other apps,
    /// and stays around when the user switches Spaces.
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
