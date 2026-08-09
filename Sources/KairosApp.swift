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

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

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
