import Foundation
import AppKit

/// Turns what the user said into plists.
///
/// Two modes, because they are genuinely different tasks and collapsing them into one "edit the plist"
/// form is why existing launchd editors are only usable by people who already know launchd:
///
///   · **Command** — one job, one plist. The generic case.
///   · **App schedule** — "open Mail at 09:00, quit it at 18:30". That is TWO launchd jobs, and making the
///     user understand why is pointless. Kairos writes both and presents them as one thing.
enum JobBuilder {

    static let kindKey = "cc.jorviksoftware.Kairos.kind"
    static let pairKey = "cc.jorviksoftware.Kairos.pair"

    struct Schedule {
        enum Kind { case interval, daily }
        var kind: Kind = .daily
        var intervalSeconds = 3600
        var hour = 9
        var minute = 0
        /// Empty = every day. Otherwise 0 = Sunday … 6 = Saturday.
        var weekdays: Set<Int> = []

        func plistValue() -> (key: String, value: Any)? {
            switch kind {
            case .interval:
                return intervalSeconds > 0 ? ("StartInterval", intervalSeconds) : nil
            case .daily:
                if weekdays.isEmpty {
                    return ("StartCalendarInterval", ["Hour": hour, "Minute": minute])
                }
                // One dict per weekday. launchd has no "list of days" form, so the UI's checkboxes have to
                // become an array — which is exactly the sort of translation people get wrong by hand.
                let arr = weekdays.sorted().map { ["Hour": hour, "Minute": minute, "Weekday": $0] }
                return ("StartCalendarInterval", arr)
            }
        }
    }

    // ── mode 1: run a command ───────────────────────────────────────────────
    static func command(label: String,
                        arguments: [String],
                        schedule: Schedule,
                        runAtLoad: Bool,
                        stdout: String?,
                        stderr: String?) -> [String: Any] {
        var d: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            kindKey: "command",
        ]
        if runAtLoad { d["RunAtLoad"] = true }
        if let (k, v) = schedule.plistValue() { d[k] = v }
        if let stdout, !stdout.isEmpty { d["StandardOutPath"] = stdout }
        if let stderr, !stderr.isEmpty { d["StandardErrorPath"] = stderr }
        return d
    }

    // ── mode 2: schedule an application ─────────────────────────────────────
    /// `open -a` rather than executing the binary inside the bundle directly: `open` hands the launch to
    /// the window server in the user's session, which is what actually makes a GUI app appear. Running
    /// `Foo.app/Contents/MacOS/Foo` from launchd gets you a process with no session and often no window.
    static func appLaunch(appName: String, appPath: String, pairID: String, schedule: Schedule) -> [String: Any] {
        var d: [String: Any] = [
            "Label": launchLabel(pairID),
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            kindKey: "app-launch",
            pairKey: pairID,
            "cc.jorviksoftware.Kairos.appName": appName,
        ]
        if let (k, v) = schedule.plistValue() { d[k] = v }
        return d
    }

    /// Quit via an AppleEvent, not `kill`. A graceful quit lets the app save and close cleanly — and it can
    /// also be REFUSED, by an app with an unsaved document or a modal sheet. Kairos does not force by
    /// default: silently destroying someone's unsaved work to keep to a schedule is the wrong trade. The
    /// editor offers a force fallback as an explicit choice.
    static func appQuit(appName: String, pairID: String, schedule: Schedule, force: Bool) -> [String: Any] {
        let script = force
            ? "tell application \"\(appName)\" to quit\ndelay 5\ntell application \"System Events\" to if exists process \"\(appName)\" then do shell script \"pkill -f '\(appName)'\""
            : "tell application \"\(appName)\" to quit"
        var d: [String: Any] = [
            "Label": quitLabel(pairID),
            "ProgramArguments": ["/usr/bin/osascript", "-e", script],
            kindKey: "app-quit",
            pairKey: pairID,
            "cc.jorviksoftware.Kairos.appName": appName,
        ]
        if let (k, v) = schedule.plistValue() { d[k] = v }
        return d
    }

    static func launchLabel(_ pairID: String) -> String { "cc.jorviksoftware.Kairos.\(pairID).launch" }
    static func quitLabel(_ pairID: String) -> String { "cc.jorviksoftware.Kairos.\(pairID).quit" }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).lowercased()
            .split(separator: "-").joined(separator: "-")
    }

    /// Applications the user could plausibly want scheduled. Reads the two Applications folders rather than
    /// asking LaunchServices for every registered bundle, which returns hundreds of helpers nobody means.
    static func installedApps() -> [(name: String, path: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for dir in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                out.append((String(n.dropLast(4)), "\(dir)/\(n)"))
            }
        }
        return out.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}
