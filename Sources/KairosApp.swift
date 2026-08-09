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
    private var clockTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // A standalone window app, not an agent: it belongs in the Dock and quits with its window.
        NSApp.setActivationPolicy(.regular)
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        startDockClock()
    }

    // ── the Dock icon tells the time ────────────────────────────────────────
    /// Only while Kairos is running: `applicationIconImage` is a property of the running application, so
    /// Finder and the Dock's own icon for a quit app still show the static bundle icon. Apple's Clock behaves
    /// the same way, for the same reason.
    ///
    /// PER MINUTE, not per second. A second hand is a handful of pixels at Dock size and would cost a redraw
    /// every second to say nothing — and the first tick is aligned to the minute boundary so the icon changes
    /// when the clock does rather than up to 59 seconds late.
    private func startDockClock() {
        tickDockClock()
        let now = Date()
        let nextMinute = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                                   matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let first = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            self?.tickDockClock()
        }
        // Generous tolerance: this is cosmetic, and letting the system coalesce the wake-up with others is
        // worth more than landing exactly on the second.
        first.tolerance = 5
        RunLoop.main.add(first, forMode: .common)
        clockTimer = first
    }

    private func tickDockClock() {
        // 512 is plenty: the Dock scales down, and no Dock tile is larger than this even on a Retina display
        // with the size slider at maximum.
        NSApp.applicationIconImage = IconRenderer.draw(size: 512, date: Date())
    }

    /// FALSE, and the live Dock clock is the reason. Terminating on last-window-close is a reasonable
    /// default for a single-window utility, and it directly kills the feature added one commit earlier: the
    /// icon can only tell the time while the app runs, so closing the window stopped the clock. Two features
    /// arguing with each other, and the window is the one that should give way.
    ///
    /// It is also the platform convention for an app with no documents — closing a window is not quitting.
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

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kairos",
            .credits: NSAttributedString(
                string: "A front end for launchd's user agents.\n\nJorvik Software",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
}
