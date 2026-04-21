import SwiftUI
#if !APP_STORE_BUILD
import Sparkle
#endif
import MachStructCore

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
    private static var _onboardingWindow: NSWindow?
    private var launchPanelObserver: Any?

    // MARK: - Sparkle auto-update (P5-06)
    //
    // `SPUStandardUpdaterController` must be held for the lifetime of the app.
    // It reads SUFeedURL and SUPublicEDKey from Info.plist automatically.
    // On first launch after install it schedules a background check; subsequent
    // checks run on the Sparkle default interval (once per day).
    //
    // startingUpdater is false in DEBUG: Sparkle refuses to start (and shows an
    // error dialog) when the app runs unsigned from DerivedData. This flag keeps
    // dev builds quiet; release builds get the real updater.
    //
    // Excluded from App Store builds (APP_STORE_BUILD): the App Store handles
    // updates and prohibits third-party auto-update mechanisms.
    #if !APP_STORE_BUILD
    let updaterController: SPUStandardUpdaterController = {
        #if DEBUG
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }()
    #endif

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be first NSDocumentController instantiation — before scenes run.
        _ = MachStructDocumentController()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showWelcome = UserDefaults.standard.object(forKey: AppSettings.Keys.showWelcomeOnLaunch)
            .flatMap { $0 as? Bool } ?? AppSettings.Defaults.showWelcomeOnLaunch
        if showWelcome {
            AppDelegate.showWelcomeWindow()
        }
        let seen = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasSeenOnboarding)
        if !seen {
            // Slight delay so the welcome window settles first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppDelegate.showOnboardingWindow()
            }
        }

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

    // MARK: - macOS Services (quick win)
    //
    // Handlers registered via NSServices in Info.plist.
    // "Format with MachStruct" → pretty-prints the selected text in place.
    // "Minify with MachStruct" → minifies the selected text in place.
    //
    // Both handlers run synchronously (macOS Services requirement).  Parsing
    // and serialisation on the current thread is acceptable for clipboard-sized
    // text; the OS times out services that don't respond within ~30 s.

    @objc func formatWithMachStruct(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pasteboard: pasteboard, pretty: true, error: error)
    }

    @objc func minifyWithMachStruct(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pasteboard: pasteboard, pretty: false, error: error)
    }

    /// Serial background queue for Services processing — avoids blocking the
    /// main thread (macOS calls service providers on the main thread).
    private static let serviceQueue = DispatchQueue(label: "com.machstruct.services")

    private func processService(
        pasteboard: NSPasteboard,
        pretty: Bool,
        error outError: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty else {
            outError.pointee = "No text on pasteboard" as NSString
            return
        }
        guard let data = text.data(using: .utf8) else { return }

        // Dispatch heavy work off the main thread.  The DispatchSemaphore blocks
        // the service queue (not the main actor), eliminating the deadlock risk.
        let sem = DispatchSemaphore(value: 0)
        var serviceResult: String?
        var serviceError: String?

        Self.serviceQueue.async {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).txt")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }

                let mapped   = try MappedFile(url: tmp)
                let detected = FormatDetector.detect(file: mapped, fileExtension: nil)

                switch detected {
                case .json, .unknown:
                    let task = Task<String?, Never> {
                        do {
                            let idx  = try await JSONParser().buildIndex(from: mapped)
                            let ni   = idx.buildNodeIndex()
                            let ser  = JSONDocumentSerializer(index: ni, mappedFile: mapped)
                            let d    = try ser.serialize(pretty: pretty)
                            return String(data: d, encoding: .utf8)
                        } catch { return nil }
                    }
                    serviceResult = DispatchSemaphore.wait(for: task)
                default:
                    serviceResult = text
                }
            } catch {
                serviceError = error.localizedDescription
            }
            sem.signal()
        }
        sem.wait()

        if let out = serviceResult {
            pasteboard.clearContents()
            pasteboard.setString(out, forType: .string)
        } else {
            outError.pointee = (serviceError ?? "Could not parse the selected text.") as NSString
        }
    }

    // MARK: - Welcome + Onboarding windows

    /// Opens the welcome window, or brings an existing one to the front.
    static func showWelcomeWindow() {
        if let existing = _welcomeWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let hosting = NSHostingController(rootView: WelcomeView())
        // Let the hosting controller calculate its preferred size from the SwiftUI layout.
        let size = hosting.sizeThatFits(in: CGSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        hosting.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to MachStruct"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 560, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _welcomeWindow = window
    }

    /// Presents the onboarding sheet as a standalone utility window.
    ///
    /// Called automatically on first launch and from Help > Show Welcome Guide.
    static func showOnboardingWindow() {
        if let existing = _onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView())
        let window  = NSWindow(contentViewController: hosting)
        window.title            = "Welcome to MachStruct"
        window.styleMask        = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        _onboardingWindow = window
    }
}

// MARK: - DispatchSemaphore helper

/// Blocks the calling thread until a Swift `Task` completes, then returns its value.
///
/// Used exclusively for the macOS Services handlers which must be synchronous.
/// Never call this on the main actor — it will deadlock.
private extension DispatchSemaphore {
    static func wait<T: Sendable>(for task: Task<T, Never>) -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: T!
        Task.detached {
            result = await task.value
            sem.signal()
        }
        sem.wait()
        return result
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

        // ── Settings window (⌘,) ─────────────────────────────────────────
        Settings {
            SettingsView()
        }
        .commands {
            // "What's New / Onboarding" in the Help menu.
            CommandGroup(replacing: .help) {
                Button("MachStruct Help") {
                    // Future: open documentation URL
                }
                .disabled(true)
                Divider()
                Button("Show Welcome Guide…") {
                    AppDelegate.showOnboardingWindow()
                }
            }
            // "Check for Updates…" is omitted from App Store builds — the App Store
            // handles updates and prohibits third-party update mechanisms (P5-07).
            #if !APP_STORE_BUILD
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.updaterController.checkForUpdates(nil)
                }
                .disabled(!appDelegate.updaterController.updater.canCheckForUpdates)
            }
            #endif

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
