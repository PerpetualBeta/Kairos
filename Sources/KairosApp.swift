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

    func applicationDidFinishLaunching(_ note: Notification) {
        // A standalone window app, not an agent: it belongs in the Dock and quits with its window.
        NSApp.setActivationPolicy(.regular)
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
