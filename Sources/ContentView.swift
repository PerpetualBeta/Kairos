import SwiftUI
import AppKit

@Observable
final class JobStore {
    var jobs: [LaunchdJob] = []
    var statuses: [String: JobStatus] = [:]
    var lastError: String?

    /// The two views the sidebar switches between. A scheduled app's three jobs appear ONLY under
    /// `schedules`, never in `plain` — listing them both ways is what makes editing one of the three
    /// possible, and editing one of three is how a schedule gets silently broken.
    var schedules: [AppSchedule] = []
    var plain: [LaunchdJob] = []

    /// Which scheduled apps are running RIGHT NOW. Held here rather than computed in the view so that the
    /// badge changes the moment an app starts or stops, instead of whenever the list is next rebuilt.
    var runningPairs: Set<String> = []
    private var appObservers: [NSObjectProtocol] = []
    private var appKitObservers: [NSObjectProtocol] = []

    /// Event-driven, not polled. `NSWorkspace` says exactly when an application appears or goes away, so
    /// there is no reason to ask on a timer — and a timer would either lag the truth or spend a wake-up a
    /// second to learn nothing.
    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.applyRunningChange(note)
            })
        }

        // Belt and braces. The deltas above are exact, but a notification missed while Kairos was in the
        // background would otherwise persist unnoticed. Recomputing when the window comes forward costs
        // one read at exactly the moment someone is about to believe what it says.
        // Tracked separately: this one lives on the default centre, and an observer must be removed from
        // the centre it was added to.
        appKitObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshRunning()
        })
    }

    deinit {
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appKitObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refreshRunning() {
        let live = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.standardizedFileURL.path
        })
        runningPairs = Set(schedules.filter { s in
            s.normalisedAppPath.map(live.contains) ?? false
        }.map(\.pair))
    }

    /// Apply one launch or termination using the notification's OWN payload, rather than re-reading
    /// `runningApplications` when it arrives.
    ///
    /// Re-reading looked simpler and was wrong. At the moment a terminate notification is delivered the
    /// dying application can still be listed, so the recompute puts it straight back — and nothing then
    /// corrects it, because the only thing that recomputes is the next launch or termination.
    ///
    /// Found 2026-08-10. ASCII Saver died at 05:00:00.501 and Rainy Day started at 05:00:00.765 — the
    /// only two events, 264ms apart, both inside that window. ASCII Saver was still badged "Running,
    /// outside its schedule" thirty-seven minutes later, and would have stayed so until the next app on
    /// the machine happened to start or stop.
    ///
    /// The payload cannot race: it names which application changed, and in which direction.
    private func applyRunningChange(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let path = app.bundleURL?.standardizedFileURL.path
        else { refreshRunning(); return }          // no payload to trust — fall back to the full read

        let started = note.name == NSWorkspace.didLaunchApplicationNotification
        for s in schedules where s.normalisedAppPath == path {
            if started { runningPairs.insert(s.pair) } else { runningPairs.remove(s.pair) }
        }
    }

    func isRunning(_ sch: AppSchedule) -> Bool { runningPairs.contains(sch.pair) }

    func reload() {
        jobs = LaunchdService.jobs()
        schedules = AppSchedule.group(jobs)
        plain = AppSchedule.plain(jobs)
        let disabled = LaunchdService.disabledLabels()
        var s: [String: JobStatus] = [:]
        for j in jobs { s[j.label] = LaunchdService.status(of: j.label, disabled: disabled) }
        statuses = s
        refreshRunning()
        seedMarkersForOpenWindows()
    }

    /// Make the marker agree with the schedule for any app that is inside its window but whose launch job
    /// has never fired.
    ///
    /// The marker is written by the launch job, so a schedule created part-way through its own window has
    /// none until the next launch time comes round — days later, or a week. Until then Kairos called the
    /// app unscheduled while it sat squarely inside its hours, and the keep-alive guard, which gates on
    /// that same marker, would not have restarted it if it had crashed.
    ///
    /// SEEDS ONLY, and only where `runs == 0`. A marker missing after the launch job HAS run means the
    /// user ended the run early, and undoing that is precisely the behaviour End Early exists to provide.
    private func seedMarkersForOpenWindows() {
        for sch in schedules where sch.isWithinScheduledWindow && !sch.isDueToRun {
            guard let l = sch.launch, (status(l).runs ?? 0) == 0 else { continue }
            if let err = JobBuilder.startEarly(sch.pair) {
                lastError = "\(sch.appName): could not open its run — \(err)"
            }
        }
    }

    /// A schedule is as loaded/failed as its worst job. Rolling three states into one is the point of the
    /// grouped view, and hiding a failure inside it would defeat that.
    func rollup(_ sch: AppSchedule) -> JobStatus {
        var r = JobStatus()
        let all = sch.jobs.map { status($0) }
        r.loaded = !all.isEmpty && all.allSatisfy { $0.loaded }
        r.disabled = all.contains { $0.disabled }
        r.pid = all.compactMap { $0.pid }.first
        r.lastExitStatus = all.compactMap { $0.lastExitStatus }.first { $0 != 0 } ?? 0
        r.runs = all.compactMap { $0.runs }.max()
        return r
    }

    func deleteSchedule(_ sch: AppSchedule) {
        var err: String?
        for j in sch.jobs { if let e = LaunchdService.delete(j) { err = e } }
        _ = JobBuilder.endEarly(sch.pair)          // no orphan marker; the guard is gone but be tidy
        lastError = err.map { "\(sch.appName): \($0)" }
        reload()
    }

    func status(_ job: LaunchdJob) -> JobStatus { statuses[job.label] ?? JobStatus() }

    func perform(_ label: String, _ action: () -> String?) {
        lastError = action().map { "\(label): \($0)" }
        reload()
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case agents = "Launch Agents"
    case apps = "Scheduled Apps"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var store = JobStore()
    @State private var mode: SidebarMode = .agents
    @State private var selection: LaunchdJob?
    @State private var selectedSchedule: AppSchedule?
    @State private var editing: EditorSeed?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(SidebarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.vertical, 8)

                switch mode {
                case .agents:
                    List(store.plain, selection: $selection) { job in
                        JobRow(job: job, status: store.status(job)).tag(job)
                    }
                    .overlay {
                        if store.plain.isEmpty {
                            ContentUnavailableView("No plain agents", systemImage: "clock.badge.questionmark",
                                                   description: Text("Nothing in ~/Library/LaunchAgents but scheduled apps."))
                        }
                    }
                case .apps:
                    List(store.schedules, selection: $selectedSchedule) { sch in
                        ScheduleRow(schedule: sch, status: store.rollup(sch), running: store.isRunning(sch)).tag(sch)
                    }
                    .overlay {
                        if store.schedules.isEmpty {
                            ContentUnavailableView("No scheduled apps", systemImage: "app.badge.clock",
                                                   description: Text("Use + to schedule one."))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            switch mode {
            case .agents:
                if let job = selection, let live = store.plain.first(where: { $0.label == job.label }) {
                    JobDetail(job: live, status: store.status(live), store: store, editing: $editing)
                } else {
                    ContentUnavailableView("Select an agent", systemImage: "sidebar.left")
                }
            case .apps:
                if let sch = selectedSchedule, let live = store.schedules.first(where: { $0.pair == sch.pair }) {
                    ScheduleDetail(schedule: live, status: store.rollup(live), running: store.isRunning(live),
                               store: store, editing: $editing)
                } else {
                    ContentUnavailableView("Select a scheduled app", systemImage: "sidebar.left")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Run a Command…") { mode = .agents; editing = EditorSeed(mode: .command) }
                    Button("Schedule an App…") { mode = .apps; editing = EditorSeed(mode: .app) }
                } label: { Label("New", systemImage: "plus") }
            }
            ToolbarItem { Button { store.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
        .sheet(item: $editing) { seed in
            JobEditor(seed: seed) { store.reload() }
        }
        .alert("launchctl reported a problem",
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
        .onAppear { store.reload() }
        .frame(minWidth: 860, minHeight: 520)
    }
}

struct JobRow: View {
    let job: LaunchdJob
    let status: JobStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 8, height: 8).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.label).lineLimit(1)
                Text(job.scheduleSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Four states, not two. Disabled and simply-not-loaded look identical in most tools and are not the
    /// same problem: one you did on purpose and forgot, the other is just off.
    private var tint: Color {
        if status.disabled { return .orange }
        if status.failed { return .red }
        if status.isRunning { return .green }
        return status.loaded ? .secondary : .gray.opacity(0.4)
    }
}

struct JobDetail: View {
    let job: LaunchdJob
    let status: JobStatus
    let store: JobStore
    @Binding var editing: EditorSeed?
    @State private var log = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.label).font(.title2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        badge(status.loaded ? "Loaded" : "Not loaded", status.loaded ? .green : .secondary)
                        if status.disabled { badge("Disabled", .orange) }
                        if let pid = status.pid { badge("Running · pid \(pid)", .green) }
                        if status.failed, let e = status.lastExitStatus { badge("Last exit \(e)", .red) }
                        if let r = status.runs { badge(r == 0 ? "Never run" : "Run \(r)×", r == 0 ? .orange : .secondary) }
                    }
                }

                if status.disabled {
                    // The trap, stated where it will actually be read.
                    Label("Disabled in launchd's own database, which is separate from this file and "
                          + "survives deleting it. Loading alone will not start it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }

                field("Schedule", job.scheduleSummary)
                field("Command", job.commandSummary)
                field("Plist", job.url.path)
                if let o = job.standardOutPath { field("Output log", o) }
                if let e = job.standardErrorPath { field("Error log", e) }


                HStack(spacing: 10) {
                    Button(status.loaded ? "Unload" : "Load") {
                        store.perform(job.label) { status.loaded ? LaunchdService.bootout(job)
                                                                : LaunchdService.bootstrap(job) }
                    }
                    Button(status.disabled ? "Enable" : "Disable") {
                        store.perform(job.label) { status.disabled ? LaunchdService.enable(job)
                                                                   : LaunchdService.disable(job) }
                    }
                    Button("Run Now") { store.perform(job.label) { LaunchdService.runNow(job) } }
                        .disabled(!status.loaded)
                    Spacer()
                    Button("Edit…") { editing = EditorSeed(existing: job) }
                        .disabled(job.isAppSchedule)     // belongs to a scheduled app; edit it there
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                    Button("Delete", role: .destructive) { store.perform(job.label) { LaunchdService.delete(job) } }
                }

                if !log.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent output").font(.headline)
                        ScrollView {
                            Text(log).font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(height: 180)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadLog)
        .onChange(of: job.label) { loadLog() }
    }

    private func loadLog() {
        let out = LaunchdService.tail(job.standardOutPath)
        let err = LaunchdService.tail(job.standardErrorPath)
        log = [err, out].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }
}

// ── the scheduled-app views ────────────────────────────────────────────────
struct ScheduleRow: View {
    let schedule: AppSchedule
    let status: JobStatus
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 8, height: 8).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.appName).lineLimit(1)
                Text(schedule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        if status.disabled { return .orange }
        if status.failed { return .red }
        return scheduleTint(schedule.state(running: running, disabled: status.disabled), loaded: status.loaded)
    }
}

/// ONE pane for a scheduled app, and one Edit for all of it.
///
/// The three underlying jobs are shown as facts — schedule, quit, guard — but never as separate things to
/// configure. Everything that changes the schedule goes through the single editor that created it, which is
/// what makes it impossible to edit the quit time believing it is the launch time.
struct ScheduleDetail: View {
    let schedule: AppSchedule
    let status: JobStatus
    let running: Bool
    let store: JobStore
    @Binding var editing: EditorSeed?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(schedule.appName).font(.title2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        badge(status.loaded ? "Loaded" : "Not loaded", status.loaded ? .green : .secondary)
                        if status.disabled { badge("Disabled", .orange) }
                        if status.failed, let e = status.lastExitStatus { badge("Last exit \(e)", .red) }
                        badge(schedule.stateLabel(running: running, disabled: status.disabled),
                              scheduleTint(schedule.state(running: running, disabled: status.disabled), loaded: status.loaded))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if schedule.isDueToRun {
                            Button("End Early") { store.perform(schedule.appName) { JobBuilder.endEarly(schedule.pair) } }
                        } else {
                            Button("Start Early") { store.perform(schedule.appName) { JobBuilder.startEarly(schedule.pair) } }
                        }
                        Spacer()
                    }
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                field("Application", schedule.appPath.isEmpty ? schedule.appName : schedule.appPath)
                field("Launches", schedule.launchSummary)
                field("Quits", schedule.quitSummary ?? "never — it stays open")
                field("If it stops", schedule.keepAliveSummary ?? "left alone")

                // The jobs, as information rather than as controls.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Implemented by").font(.caption).foregroundStyle(.secondary)
                    ForEach(schedule.jobs) { j in
                        Text(j.label).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    Button(status.loaded ? "Unload" : "Load") {
                        store.perform(schedule.appName) {
                            var e: String?
                            for j in schedule.jobs {
                                if let x = status.loaded ? LaunchdService.bootout(j) : LaunchdService.bootstrap(j) { e = x }
                            }
                            return e
                        }
                    }
                    Button(status.disabled ? "Enable" : "Disable") {
                        store.perform(schedule.appName) {
                            var e: String?
                            for j in schedule.jobs {
                                if let x = status.disabled ? LaunchdService.enable(j) : LaunchdService.disable(j) { e = x }
                            }
                            return e
                        }
                    }
                    Spacer()
                    Button("Edit…") { editing = EditorSeed(schedule: schedule) }
                    Button("Delete", role: .destructive) { store.deleteSchedule(schedule) }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Says what is true first, then what the button beside it will do. The End/Start Early control is the
    /// thing being explained, so each case has to make sense of pressing it in that state.
    private var caption: String {
        switch schedule.state(running: running, disabled: status.disabled) {
        case .running:
            return "\(schedule.appName) is running and due to be, so it will be restarted if it stops. "
                 + "Ending early stops that — it does not quit the app."
        case .shouldBeRunning:
            return "\(schedule.appName) is due to be running but is not. If it is kept running it will be "
                 + "started again at the next check; otherwise nothing will start it until its next launch "
                 + "time. Ending early cancels the rest of this run."
        case .runningUnscheduled:
            return "\(schedule.appName) is running outside its scheduled hours — opened by hand, or left "
                 + "over from an earlier run. Its quit job will still close it at the scheduled time."
        case .endedEarly:
            return "\(schedule.appName) is inside its scheduled hours, but this run was ended early, so "
                 + "it will not be restarted if it stops. Starting early resumes it for the rest of the run."
        case .disabled:
            return "\(schedule.appName)'s jobs are disabled in launchd, so nothing will start it at its "
                 + "scheduled time — not even a reboot. Enable them to put the schedule back in force."
        case .idle:
            return "\(schedule.appName) is scheduled, but its run has not started yet. Starting early "
                 + "brings it forward without changing the schedule."
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }
}

/// The states, coloured. Shared by the sidebar dot and the detail badge so the two can never drift.
///
/// Orange is the only alarming one, and deliberately so: an app that is due to be running and is not is the
/// single state here that means something has gone wrong.
func scheduleTint(_ state: AppSchedule.State, loaded: Bool) -> Color {
    switch state {
    case .running: return .green
    case .shouldBeRunning: return .orange
    case .runningUnscheduled: return .blue
    case .endedEarly: return .secondary        // deliberate, so not a warning
    case .idle: return loaded ? .secondary : .gray.opacity(0.4)
    // Switched off on purpose, so it is not a warning — the same reasoning as `.endedEarly`.
    case .disabled: return .secondary
    }
}
