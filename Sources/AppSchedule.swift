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

    /// Is a run currently ACTIVE? This is the marker file — written by the launch job, cleared by the quit
    /// job — and it is what the keep-alive guard gates on.
    var isDueToRun: Bool { JobBuilder.isDueToRun(pair) }

    /// Does the SCHEDULE say this app should be running right now?
    ///
    /// Derived from the launch and quit calendar entries, and deliberately independent of the marker above.
    /// The two normally agree. They disagree for every schedule between being created and its first launch
    /// time coming round: the marker is written *by* the launch job, so until that job has fired even once
    /// there is nothing on disk, and the app reported itself outside a window it was plainly inside — while
    /// the guard, gating on the same absent marker, sat inert and would not have restarted a crash.
    ///
    /// Found 2026-08-09: ASCII Saver scheduled Friday 18:00 → Monday 05:00, inspected on the Sunday, with
    /// `runs = 0` on its launch job.
    var isWithinScheduledWindow: Bool {
        let now = Date()
        guard let l = launch, !l.calendarIntervals.isEmpty,
              let lastLaunch = Self.lastOccurrence(l.calendarIntervals, atOrBefore: now)
        else { return false }
        guard let q = quit, !q.calendarIntervals.isEmpty,
              let lastQuit = Self.lastOccurrence(q.calendarIntervals, atOrBefore: now)
        else { return true }              // nothing quits it, so once launched it stays up
        return lastLaunch > lastQuit
    }

    /// The most recent moment one of these calendar entries fired, at or before `now`.
    ///
    /// Searching backwards is what makes a span work across days: the window is open when the last launch
    /// is more recent than the last quit, which is true on a Sunday for a Friday-to-Monday schedule without
    /// any special-casing of multi-day spans.
    private static func lastOccurrence(_ intervals: [[String: Int]], atOrBefore now: Date) -> Date? {
        let cal = Calendar.current
        return intervals.compactMap { c -> Date? in
            var m = DateComponents()
            m.hour = c["Hour"]; m.minute = c["Minute"] ?? 0
            if let w = c["Weekday"] { m.weekday = (w % 7) + 1 }   // launchd 0=Sunday, Calendar 1=Sunday
            if let d = c["Day"] { m.day = d }
            if let mo = c["Month"] { m.month = mo }
            return cal.nextDate(after: now, matching: m, matchingPolicy: .nextTime, direction: .backward)
        }.max()
    }

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

    /// The badge. FOUR states, because "due" and "running" are independent facts and the interesting cases
    /// are the two where they disagree.
    ///
    /// Reporting "Should be running now" for an app that plainly WAS running stated the schedule's intent
    /// when the fact itself was there for the asking. Intent is only worth showing when it differs from
    /// reality — and then it is worth showing loudly, because a disagreement means something is wrong.
    ///
    /// `running` comes from the store rather than being read here, so that the badge updates when the app
    /// starts or stops rather than only when the list is next rebuilt.
    enum State { case running, shouldBeRunning, runningUnscheduled, endedEarly, idle }

    func state(running: Bool) -> State {
        // Inside the window with no active run can only mean the run was ended by hand: the store seeds
        // the marker for any in-window schedule whose launch job has never fired, so a missing marker is
        // no longer ambiguous. Checked first, or this would masquerade as one of the pairs below.
        if isWithinScheduledWindow && !isDueToRun { return .endedEarly }

        switch (isDueToRun, running) {
        case (true, true):   return .running
        case (true, false):  return .shouldBeRunning      // the guard has not caught up, or there is none
        case (false, true):  return .runningUnscheduled   // opened by hand, or outside its hours
        case (false, false): return .idle
        }
    }

    func stateLabel(running: Bool) -> String {
        switch state(running: running) {
        case .running: return "Running"
        case .shouldBeRunning: return "Should be running — it is not"
        case .runningUnscheduled: return "Running, outside its schedule"
        case .endedEarly: return running ? "Running — this run was ended early" : "This run was ended early"
        case .idle:
            guard let next = nextLaunch else { return "Not running" }
            let cal = Calendar.current
            let f = DateFormatter()
            if cal.isDateInToday(next) { f.dateFormat = "'Today' HH:mm" }
            else if cal.isDateInTomorrow(next) { f.dateFormat = "'Tomorrow' HH:mm" }
            else { f.dateFormat = "EEE HH:mm" }
            return "Next run \(f.string(from: next))"
        }
    }

    /// The bundle path this schedule launches, normalised for comparison against a running application.
    /// Matched on path rather than name: two apps can share a display name, and a bundle's executable is
    /// frequently not called what the app is called.
    var normalisedAppPath: String? {
        appPath.isEmpty ? nil : URL(fileURLWithPath: appPath).standardizedFileURL.path
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
