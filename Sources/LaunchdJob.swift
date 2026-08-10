import Foundation

/// One user LaunchAgent: the plist on disk, plus enough understanding of it to describe it in English.
///
/// SCOPE, DELIBERATE: user agents in `~/Library/LaunchAgents` only. Not `/Library/LaunchDaemons`, which
/// would need a privileged helper — and which cannot launch a GUI application into a login session anyway,
/// so it is the wrong tool for the thing this app exists to make easy.
struct LaunchdJob: Identifiable, Hashable {
    var id: String { label }

    var label: String
    var url: URL
    /// Everything the plist contained, so a round-trip cannot silently drop keys this app does not model.
    var raw: [String: Any]

    var programArguments: [String] {
        if let a = raw["ProgramArguments"] as? [String] { return a }
        if let p = raw["Program"] as? String { return [p] }
        return []
    }
    var runAtLoad: Bool { raw["RunAtLoad"] as? Bool ?? false }
    var standardOutPath: String? { raw["StandardOutPath"] as? String }
    var standardErrorPath: String? { raw["StandardErrorPath"] as? String }
    var startInterval: Int? { raw["StartInterval"] as? Int }

    /// `StartCalendarInterval` is either one dict or an array of them. Normalised so callers need not care.
    var calendarIntervals: [[String: Int]] {
        if let d = raw["StartCalendarInterval"] as? [String: Int] { return [d] }
        if let a = raw["StartCalendarInterval"] as? [[String: Int]] { return a }
        return []
    }

    /// What this app wrote, if it wrote it. Lets the editor reopen an "app schedule" as an app schedule
    /// rather than as a raw command, without guessing from the arguments.
    var kairosKind: String? { raw["cc.jorviksoftware.Kairos.kind"] as? String }
    /// Which app-schedule this job belongs to, if any. The launch, quit and guard jobs of one schedule all
    /// carry the same pair, which is what lets the UI treat three plists as one thing.
    var kairosPair: String? { raw["cc.jorviksoftware.Kairos.pair"] as? String }
    var kairosAppName: String? { raw["cc.jorviksoftware.Kairos.appName"] as? String }
    /// The bundle this job acts on.
    ///
    /// Prefers the metadata key, but falls back to reading the path back out of the command when the key
    /// is absent — which it is for every schedule written before the key existed. Those jobs are not
    /// broken: the path is right there in the command they run. Only the *label* on it is missing.
    ///
    /// Without the fallback, `appPath` stays empty, `normalisedAppPath` is nil, and the running check
    /// answers "not running" unconditionally for that app — for ever, with no error anywhere. Found
    /// 2026-08-10: Rainy Day's three jobs had no metadata key, so it was reported "Should be running —
    /// it is not" while it had been running perfectly since 05:00:00.765.
    var kairosAppPath: String? {
        if let p = raw["cc.jorviksoftware.Kairos.appPath"] as? String, !p.isEmpty { return p }
        return Self.appPath(inCommand: programArguments)
    }

    /// Recover a bundle path from the command a Kairos job runs. Launch and keep-alive jobs contain
    /// `open -a '<path>'`; quit and keep-alive jobs contain `'<path>/Contents/MacOS/'`.
    static func appPath(inCommand args: [String]) -> String? {
        let cmd = args.joined(separator: " ")
        for pattern in [#"open -a '([^']+\.app)'"#, #"'([^']+\.app)/Contents/MacOS/'"#] {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: cmd)
            else { continue }
            return String(cmd[r])
        }
        return nil
    }
    var isAppSchedule: Bool { kairosKind?.hasPrefix("app") ?? false }

    // ── description ─────────────────────────────────────────────────────────
    var commandSummary: String {
        programArguments.isEmpty ? "—" : programArguments.joined(separator: " ")
    }

    /// The schedule in English. Reading `Minute => 30, Hour => 18` and doing the arithmetic in your head is
    /// the single most annoying thing about launchd plists, so it is the first thing this app removes.
    var scheduleSummary: String {
        var parts: [String] = []
        if let s = startInterval { parts.append("every \(Self.humanInterval(s))") }
        for c in calendarIntervals { parts.append(Self.humanCalendar(c)) }
        if parts.isEmpty && runAtLoad { return "at login only" }
        if runAtLoad { parts.append("and at login") }
        return parts.isEmpty ? "no schedule" : parts.joined(separator: ", ")
    }

    static func humanInterval(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { let d = seconds / 86_400; return d == 1 ? "day" : "\(d) days" }
        if seconds % 3_600 == 0 { let h = seconds / 3_600; return h == 1 ? "hour" : "\(h) hours" }
        if seconds % 60 == 0 { let m = seconds / 60; return m == 1 ? "minute" : "\(m) minutes" }
        return "\(seconds)s"
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func humanCalendar(_ c: [String: Int]) -> String {
        let h = c["Hour"], m = c["Minute"]
        let time: String
        switch (h, m) {
        case let (h?, m?): time = String(format: "%02d:%02d", h, m)
        case let (h?, nil): time = String(format: "%02d:00 (every minute of that hour)", h)
        case let (nil, m?): time = String(format: "every hour at :%02d", m)
        default: time = "every minute"
        }
        var when = time
        // Weekday 0 and 7 both mean Sunday in launchd, which is the kind of detail a UI should absorb.
        if let w = c["Weekday"] { when += " on \(weekdayNames[w % 7])" }
        if let d = c["Day"] { when += " on the \(ordinal(d))" }
        if let mo = c["Month"] { when += " in month \(mo)" }
        return when
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // ── disk ────────────────────────────────────────────────────────────────
    static func load(from url: URL) -> LaunchdJob? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let label = dict["Label"] as? String
        else { return nil }
        return LaunchdJob(label: label, url: url, raw: dict)
    }

    func write() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func == (a: LaunchdJob, b: LaunchdJob) -> Bool { a.label == b.label && a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(label); h.combine(url) }
}

/// What launchd currently thinks of a job, as distinct from what the file on disk says.
///
/// These are genuinely independent: a plist can exist and not be loaded, be loaded and disabled, or be
/// loaded from a file that has since been edited. Showing them as one "on/off" is the lie most launchd
/// front ends tell.
struct JobStatus {
    var loaded = false
    var disabled = false
    var pid: Int?
    var lastExitStatus: Int?
    /// How many times launchd has started it. Zero on a loaded, enabled, healthy-looking job means the
    /// schedule has never fired — the failure mode no status light shows.
    var runs: Int?

    var isRunning: Bool { pid != nil }
    /// The only failure signal launchd reliably gives you, and it is easy to miss because a job that exits
    /// non-zero simply is not there any more.
    var failed: Bool { (lastExitStatus ?? 0) != 0 }
}
