import SwiftUI
import AppKit
import Sparkle

@main
struct KairosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kairos", id: "main") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Kairos") { delegate.showAbout() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Kairos Window") { delegate.reopenWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ note: Notification) {
        // A standalone window app, not an agent: it belongs in the Dock and quits with its window.
        NSApp.setActivationPolicy(.regular)
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// FALSE: the platform convention for an app with no documents. Closing a window is not quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// Which makes the Dock icon the way back in. Without this, closing the window would leave a running app
    /// with no way to show itself again — worse than terminating.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible { showMainWindow() }
        return true
    }

    func reopenWindow() { showMainWindow() }

    private func showMainWindow() {
        // The SwiftUI `Window` scene keeps its NSWindow when closed, so this orders the existing one back
        // rather than building a second.
        if let w = NSApp.windows.first(where: { $0.contentViewController != nil || $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func checkForUpdates() { updater?.checkForUpdates(nil) }

    /// The Jorvik About window every Jorvik app shows: version, the public
    /// domain declaration, and the Source Code and Product Page links. Kairos
    /// used AppKit's standard panel, which has none of those. The shared
    /// window also opens on the current space (`JorvikWindowHelper`).
    func showAbout() {
        JorvikAboutView.showWindow(appName: "Kairos", repoName: "Kairos", productPage: "apps/kairos")
    }
}
