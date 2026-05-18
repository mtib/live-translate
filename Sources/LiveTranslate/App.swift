import SwiftUI

@main
struct LiveTranslateApp: App {
    @StateObject private var pipeline = Pipeline()
    @State private var mainWindow: NSWindow?
    @State private var isWindowVisible = true

    init() {
        Log.startup()  // truncates the log if it's grown past the cap
        // Recover any sessions whose previous app instance died before
        // finalize completed. Runs in the background; doesn't block
        // the UI or interfere with new sessions.
        Task.detached(priority: .background) {
            await CrashRecovery.recoverPendingSessions()
        }
    }

    var body: some Scene {
        Window("LiveTranslate", id: "main") {
            TranscriptView(pipeline: pipeline)
                .frame(minWidth: 260, minHeight: 80)
                .background(WindowAccessor { window in
                    mainWindow = window
                    configure(window)
                })
                .onAppear { installTerminateHook(pipeline: pipeline) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 480)
        .commands {
            // Native macOS menu-bar entries. The Debug menu is small
            // but exists so screenshots can be captured in a known UI
            // state without recording real audio.
            CommandMenu("Debug") {
                Button("Load fixture sentences") {
                    pipeline.loadDebugFixtures()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Clear sentences") {
                    pipeline.clear()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(
                pipeline: pipeline,
                isWindowVisible: $isWindowVisible,
                mainWindow: mainWindow
            )
        } label: {
            Image(systemName: pipeline.isRunning
                ? "bubble.left.and.text.bubble.right.fill"
                : "bubble.left.and.text.bubble.right")
        }
        .menuBarExtraStyle(.window)
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
        window.level = .statusBar
        // Extend our content into the title-bar area so the hidden
        // traffic-light strip doesn't leave a dead band of background
        // above the controls. The View ignores the safe area to match.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Hide all traffic lights — the app is meant to be a small floating
        // overlay and the title-bar chrome eats vertical real estate. Use
        // Cmd+Q (or the app menu) to quit; the window drags from anywhere
        // thanks to isMovableByWindowBackground.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak window] _ in
            guard window?.isVisible == true else { return }
            window?.orderFrontRegardless()
        }
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
