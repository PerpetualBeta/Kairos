import Foundation

/// One scheduled application, assembled from the two or three launchd jobs that implement it.
///
/// WHY THIS TYPE EXISTS. A scheduled app is three plists — launch, quit, and the keep-alive guard — and
/// listing them separately invites the user to edit one of them alone. That is not merely confusing, it
/// misconfigures: opening the *quit* job in the app editor would present its time as the launch time, and
/// saving would write that back. The three are one thing and must be presented as one thing.
struct AppSchedule: Identifiable, Hashable {
    var id: String { pair }
    var pair: String
    var appName: String
    var appPath: String

    var launch: LaunchdJob?
    var quit: LaunchdJob?
    var keepAlive: LaunchdJob?

    var jobs: [LaunchdJob] { [launch, quit, keepAlive].compactMap { $0 } }

    var launchSummary: String { launch?.scheduleSummary ?? "no launch" }
    var quitSummary: String? { quit?.scheduleSummary }
    var keepAliveSummary: String? {
        guard let s = keepAlive?.startInterval else { return nil }
        return "checked every \(LaunchdJob.humanInterval(s))"
    }

    /// A one-line description for the sidebar. The launch is the headline; the quit is what makes it a
    /// span rather than a moment.
    var summary: String {
        guard let q = quitSummary else { return launchSummary }
        return "\(launchSummary) → \(q)"
    }

    var isDueToRun: Bool { JobBuilder.isDueToRun(pair) }

    /// When this will next start, from the launch job's own calendar entries.
    ///
    /// Nil for an interval schedule, where the next fire depends on launchd's internal timer and cannot be
    /// derived from the plist — better to say nothing than to state a time that is a guess.
    var nextLaunch: Date? {
        guard let l = launch, !l.calendarIntervals.isEmpty else { return nil }
        let cal = Calendar.current, now = Date()
        return l.calendarIntervals.compactMap { c -> Date? in
            var m = DateComponents()
            m.hour = c["Hour"]; m.minute = c["Minute"] ?? 0
            if let w = c["Weekday"] { m.weekday = (w % 7) + 1 }     // launchd 0=Sunday, Calendar 1=Sunday
            if let d = c["Day"] { m.day = d }
            if let mo = c["Month"] { m.month = mo }
            return cal.nextDate(after: now, matching: m, matchingPolicy: .nextTime)
        }.min()
    }

    /// The badge, and it must be about NOW.
    ///
    /// "Due to run" read as a future obligation for an app that was already inside its window, and "Not due
    /// to run" read as *not scheduled at all* for one that simply had not started yet. Both were about the
    /// present and neither said so. Naming the next start removes the second misreading entirely.
    var stateLabel: String {
        if isDueToRun { return "Should be running now" }
        guard let next = nextLaunch else { return "Not running now" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(next) { f.dateFormat = "'Today' HH:mm" }
        else if cal.isDateInTomorrow(next) { f.dateFormat = "'Tomorrow' HH:mm" }
        else { f.dateFormat = "EEE HH:mm" }
        return "Next run \(f.string(from: next))"
    }

    /// Group whatever is on disk into schedules. Tolerant on purpose: a schedule whose quit job has been
    /// deleted by hand is still a schedule, and should be shown rather than vanish.
    static func group(_ jobs: [LaunchdJob]) -> [AppSchedule] {
        var byPair: [String: AppSchedule] = [:]
        for j in jobs where j.isAppSchedule {
            guard let pair = j.kairosPair else { continue }
            var s = byPair[pair] ?? AppSchedule(pair: pair,
                                                appName: j.kairosAppName ?? pair,
                                                appPath: j.kairosAppPath ?? "")
            if s.appPath.isEmpty, let p = j.kairosAppPath { s.appPath = p }
            switch j.kairosKind {
            case "app-launch":    s.launch = j
            case "app-quit":      s.quit = j
            case "app-keepalive": s.keepAlive = j
            default: break
            }
            byPair[pair] = s
        }
        return byPair.values.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    /// Everything that is NOT part of a scheduled app — the plain agents, which is what the other view shows.
    static func plain(_ jobs: [LaunchdJob]) -> [LaunchdJob] { jobs.filter { !$0.isAppSchedule } }
}
