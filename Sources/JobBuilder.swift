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
    /// Where the "this app is supposed to be running" markers live. A file rather than state inside Kairos,
    /// deliberately: the jobs run whether or not Kairos is open, and must not depend on it.
    /// Single-quote for `/bin/sh`. Paths are user data — "/Applications/Bob's App.app" would otherwise close
    /// the quote and hand the rest of the path to the shell as code. The POSIX idiom for an embedded single
    /// quote is to close, escape one, and reopen.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// And for an AppleScript string literal, where the hazards are the double quote and the backslash.
    static func asq(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static var markerDirectory: String { "\(NSHomeDirectory())/Library/Application Support/Kairos/windows" }
    static func markerPath(_ pairID: String) -> String { "\(markerDirectory)/\(pairID)" }

    /// Is this app currently *due* to be running? Distinct from whether it happens to be running: this is
    /// the schedule's intent, and the guard is what reconciles intent with reality.
    ///
    /// This was called an open "window" until someone reasonably read that as an application window — the
    /// most loaded noun on the platform, and not one to spend on a metaphor.
    static func isDueToRun(_ pairID: String) -> Bool {
        FileManager.default.fileExists(atPath: markerPath(pairID))
    }

    /// End the run early. Without this, quitting a kept-alive app yourself achieves nothing — the guard
    /// restores it within the check interval, which is correct behaviour and infuriating if it is not what
    /// you meant. The app is left alone: this says "stop expecting it to be running", not "kill it".
    static func endEarly(_ pairID: String) -> String? {
        do { try FileManager.default.removeItem(atPath: markerPath(pairID)); return nil }
        catch CocoaError.fileNoSuchFile { return nil }          // already closed is success, not an error
        catch { return error.localizedDescription }
    }

    /// And start it early, so a schedule can begin before its time without editing the times.
    static func startEarly(_ pairID: String) -> String? {
        do {
            try FileManager.default.createDirectory(atPath: markerDirectory,
                                                    withIntermediateDirectories: true)
            try Date().description.write(toFile: markerPath(pairID), atomically: true, encoding: .utf8)
            return nil
        } catch { return error.localizedDescription }
    }

    /// `open -a` rather than executing the binary inside the bundle directly: `open` hands the launch to
    /// the window server in the user's session, which is what actually makes a GUI app appear. Running
    /// `Foo.app/Contents/MacOS/Foo` from launchd gets you a process with no session and often no window.
    ///
    /// It also OPENS THE WINDOW — the marker file that says this app is meant to be running until the quit
    /// job removes it. That is what lets a schedule span days, and what the keep-alive guard tests.
    static func appLaunch(appName: String, appPath: String, pairID: String, schedule: Schedule) -> [String: Any] {
        let sh = "mkdir -p \(shq(markerDirectory)) && date > \(shq(markerPath(pairID))) && "
               + "/usr/bin/open -a \(shq(appPath))"
        var d: [String: Any] = [
            "Label": launchLabel(pairID),
            "ProgramArguments": ["/bin/sh", "-c", sh],
            kindKey: "app-launch",
            pairKey: pairID,
            "cc.jorviksoftware.Kairos.appName": appName,
            "cc.jorviksoftware.Kairos.appPath": appPath,
        ]
        if let (k, v) = schedule.plistValue() { d[k] = v }
        return d
    }

    /// KEEP IT RUNNING, and note what this is NOT: launchd's own `KeepAlive` on the launch job. That job is
    /// `open`, which exits the moment the app is up — so `KeepAlive` there would have launchd relaunching
    /// `open` in a tight loop forever. "Keep this process alive" and "keep that application running" are
    /// different requests, and only the second one is ever what someone means here.
    ///
    /// So: a small guard on an interval. If the window is open and the app is not running, start it. The
    /// `pgrep -f` matches the executable's full path rather than a process name, because a bundle's
    /// executable is often not called what the app is called.
    static func appKeepAlive(appName: String, appPath: String, pairID: String,
                             everyMinutes: Int) -> [String: Any] {
        let sh = "[ -f \(shq(markerPath(pairID))) ] || exit 0; "
               + "/usr/bin/pgrep -f \(shq(appPath + "/Contents/MacOS/")) > /dev/null && exit 0; "
               + "/usr/bin/open -a \(shq(appPath))"
        return [
            "Label": keepAliveLabel(pairID),
            "ProgramArguments": ["/bin/sh", "-c", sh],
            "StartInterval": max(1, everyMinutes) * 60,
            kindKey: "app-keepalive",
            pairKey: pairID,
            "cc.jorviksoftware.Kairos.appName": appName,
            "cc.jorviksoftware.Kairos.appPath": appPath,
        ]
    }

    /// Quit via an AppleEvent, not `kill`. A graceful quit lets the app save and close cleanly — and it can
    /// also be REFUSED, by an app with an unsaved document or a modal sheet. Kairos does not force by
    /// default: silently destroying someone's unsaved work to keep to a schedule is the wrong trade. The
    /// editor offers a force fallback as an explicit choice.
    static func appQuit(appName: String, appPath: String, pairID: String,
                        schedule: Schedule, force: Bool) -> [String: Any] {
        let quit = "/usr/bin/osascript -e " + shq("tell application \"\(asq(appName))\" to quit")
        let exe = shq(appPath + "/Contents/MacOS/")
        // `if`, not `pgrep && pkill`. The `&&` form makes the job's exit status the status of `pgrep`,
        // so the ordinary outcome — the graceful quit worked, nothing left to force — short-circuits and
        // launchd records the job as having FAILED every single time it succeeded. Observed 2026-08-10:
        // ascii-saver.quit sitting at exit 1 after a textbook quit.
        //
        // An `if` whose condition is false exits 0, so a clean quit reports success. A `pkill` that
        // actually runs and fails still propagates, which is the one outcome worth hearing about.
        let forceTail = " ; sleep 5; if /usr/bin/pgrep -f \(exe) > /dev/null; then /usr/bin/pkill -f \(exe); fi"
        // Close the window FIRST. If the marker outlived the quit, the keep-alive guard would helpfully
        // relaunch the app seconds after it was asked to stop — the two jobs fighting each other forever.
        let sh = "rm -f \(shq(markerPath(pairID))); " + quit + (force ? forceTail : "")
        var d: [String: Any] = [
            "Label": quitLabel(pairID),
            "ProgramArguments": ["/bin/sh", "-c", sh],
            kindKey: "app-quit",
            pairKey: pairID,
            "cc.jorviksoftware.Kairos.appName": appName,
            "cc.jorviksoftware.Kairos.appPath": appPath,
        ]
        if let (k, v) = schedule.plistValue() { d[k] = v }
        return d
    }

    static func launchLabel(_ pairID: String) -> String { "cc.jorviksoftware.Kairos.\(pairID).launch" }
    static func quitLabel(_ pairID: String) -> String { "cc.jorviksoftware.Kairos.\(pairID).quit" }
    static func keepAliveLabel(_ pairID: String) -> String { "cc.jorviksoftware.Kairos.\(pairID).keepalive" }

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
