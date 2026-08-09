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
