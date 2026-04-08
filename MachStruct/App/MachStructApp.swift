import SwiftUI

// MARK: - MachStructDocumentController

/// NSDocumentController subclass that suppresses the automatic Open panel
/// DocumentGroup fires at launch.
///
/// Per Apple docs, a custom subclass must be the *first* NSDocumentController
/// instantiated — done in applicationWillFinishLaunching (see AppDelegate).
///
/// Two entry points are intercepted because DocumentGroup may call either:
///   • openDocument(_:)       — the high-level "show Open panel" action
///   • beginOpenPanel(…)      — the lower-level panel-display method
final class MachStructDocumentController: NSDocumentController {

    /// While true every path that would show the Open panel is a no-op.
    /// Cleared on the next run-loop cycle after applicationDidFinishLaunching
    /// so File > Open and WelcomeView's button work normally.
    var suppressOpen = true

    override func openDocument(_ sender: Any?) {
        guard !suppressOpen else { return }
        super.openDocument(sender)
    }

    override func beginOpenPanel(
        _ openPanel: NSOpenPanel,
        forTypes inTypes: [String]?,
        completionHandler: @escaping (Int) -> Void
    ) {
        guard !suppressOpen else {
            completionHandler(NSApplication.ModalResponse.cancel.rawValue)
            return
        }
        super.beginOpenPanel(openPanel, forTypes: inTypes,
                             completionHandler: completionHandler)
    }
}

// MARK: - AppDelegate

/// Handles app-lifecycle events that have no SwiftUI equivalent.
///
/// Open-panel suppression uses two strategies in tandem:
///
/// **Strategy A — NSDocumentController override**
/// MachStructDocumentController is created in applicationWillFinishLaunching
/// (the documented moment) so it wins the shared-instance race. suppressOpen
/// is cleared on the *next* run-loop cycle so DocumentGroup's async panel
/// call is still gated when it fires.
///
/// **Strategy B — NSOpenPanel notification observer**
/// In case DocumentGroup bypasses NSDocumentController entirely, a short-lived
/// observer watches for NSOpenPanel becoming key and cancels it. The observer
/// self-destructs after the first panel (so user-triggered panels are never
/// affected) and is force-removed after 0.5 s regardless.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static var _welcomeWindow: NSWindow?
    private var launchPanelObserver: Any?

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be first NSDocumentController instantiation — before scenes run.
        _ = MachStructDocumentController()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.showWelcomeWindow()

        // Strategy A: defer flag-clear to next cycle so DocumentGroup's async
        // openDocument call arrives while suppressOpen is still true.
        DispatchQueue.main.async {
            (NSDocumentController.shared as? MachStructDocumentController)?
                .suppressOpen = false
        }

        // Strategy B: short-lived observer that cancels any NSOpenPanel that
        // becomes key during the launch window (≤ 0.5 s after launch).
        // Removes itself after the first panel it sees, or after 0.5 s —
        // whichever comes first — so user-triggered panels are never touched.
        launchPanelObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard note.object is NSOpenPanel else { return }
            (note.object as? NSOpenPanel)?.cancel(nil)
            self?.removeLaunchPanelObserver()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.removeLaunchPanelObserver()
        }
    }

    private func removeLaunchPanelObserver() {
        guard let obs = launchPanelObserver else { return }
        NotificationCenter.default.removeObserver(obs)
        launchPanelObserver = nil
    }

    // MARK: Re-open (Dock click with no visible windows)

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            AppDelegate.showWelcomeWindow()
        }
        return true
    }

    // MARK: Welcome window

    /// Opens the welcome window, or brings an existing one to the front.
    static func showWelcomeWindow() {
        if let existing = _welcomeWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let hosting = NSHostingController(rootView: WelcomeView())
        // Let the hosting controller calculate its preferred size from the SwiftUI layout.
        let size = hosting.sizeThatFits(in: CGSize(width: 560, height: CGFloat.greatestFiniteMagnitude))
        hosting.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to MachStruct"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _welcomeWindow = window
    }
}

// MARK: - MachStructApp

@main
struct MachStructApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // DocumentGroup wires up:
        //   • File > Open  (Cmd+O)
        //   • File > Open Recent
        //   • Drag-and-drop onto the Dock icon or an open document window
        //   • One window per open document
        DocumentGroup(viewing: StructDocument.self) { file in
            ContentView(document: file.document)
                .frame(minWidth: 600, minHeight: 400)
        }
        .commands {
            CommandGroup(after: .windowList) {
                Divider()
                Button("Show Welcome Window") {
                    AppDelegate.showWelcomeWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
    }
}
