import SwiftUI
import AppKit

struct EditorSeed: Identifiable {
    enum Mode { case command, app }
    var id = UUID()
    var mode: Mode = .command
    var existing: LaunchdJob?

    init(mode: Mode) { self.mode = mode }
    init(existing: LaunchdJob) {
        self.existing = existing
        // Reopen an app schedule as an app schedule. This is why `JobBuilder.kindKey` is written into the
        // plist: guessing the mode back from ProgramArguments would be fragile and would break the moment
        // someone hand-edited the file.
        self.mode = (existing.kairosKind?.hasPrefix("app") ?? false) ? .app : .command
    }
}

struct JobEditor: View {
    let seed: EditorSeed
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode: EditorSeed.Mode = .command
    @State private var error: String?

    // command mode
    @State private var label = ""
    @State private var command = ""
    @State private var runAtLoad = false
    @State private var stdout = ""
    @State private var stderr = ""

    // app mode
    @State private var appName = ""
    @State private var appPath = ""
    @State private var quitEnabled = true
    @State private var forceQuit = false
    @State private var quitHour = 18
    @State private var quitMinute = 30
    /// The quit's own days, independent of the launch's. Sharing one set makes "start Friday evening, stop
    /// Monday morning" impossible to express, which is the commonest thing anyone actually wants.
    @State private var quitWeekdays: Set<Int> = []
    @State private var keepAlive = false
    @State private var keepAliveMinutes = 5

    // shared schedule
    @State private var kind: JobBuilder.Schedule.Kind = .daily
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekdays: Set<Int> = []
    @State private var intervalMinutes = 60

    private var isEditing: Bool { seed.existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Agent" : (mode == .app ? "Schedule an App" : "Run a Command"))
                .font(.title3).padding(20)

            Divider()

            Form {
                if mode == .app { appSection } else { commandSection }

                Section(mode == .app ? "Launch at" : "Schedule") {
                    Picker("Repeat", selection: $kind) {
                        Text("At a time of day").tag(JobBuilder.Schedule.Kind.daily)
                        Text("Every…").tag(JobBuilder.Schedule.Kind.interval)
                    }.pickerStyle(.segmented)

                    if kind == .daily {
                        timeRow("Time", hour: $hour, minute: $minute)
                        weekdayRow
                    } else {
                        HStack {
                            Text("Every")
                            TextField("", value: $intervalMinutes, format: .number).frame(width: 70)
                            Text("minutes")
                        }
                    }
                }

                if mode == .app {
                    Section("Quit") {
                        Toggle("Quit it again later", isOn: $quitEnabled)
                        if quitEnabled {
                            timeRow("Time", hour: $quitHour, minute: $quitMinute)
                            dayRow(selection: $quitWeekdays, emptyLabel: "same day it launched")
                            Toggle("Force quit if it refuses", isOn: $forceQuit)
                            // Say the cost out loud at the point of choosing, not in a manual.
                            Text(forceQuit
                                 ? "Waits five seconds for a clean quit, then kills it. An unsaved document will be lost."
                                 : "A graceful quit can be refused — an app with unsaved changes will put up a dialog and stay open.")
                                .font(.caption).foregroundStyle(forceQuit ? .orange : .secondary)
                        }
                    }

                    Section("While it should be running") {
                        Toggle("Restart it if it stops", isOn: $keepAlive)
                        if keepAlive {
                            HStack {
                                Text("Check every")
                                TextField("", value: $keepAliveMinutes, format: .number).frame(width: 60)
                                Text("minutes")
                            }
                            Text("Kairos marks the app as due to be running between the launch and the quit, "
                               + "even across days, and restarts it if it is not. This is not launchd's own "
                               + "KeepAlive, which would watch the launcher rather than the app and relaunch "
                               + "it in a loop forever.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560)
        .onAppear(perform: seedFields)
    }

    // ── sections ────────────────────────────────────────────────────────────
    private var commandSection: some View {
        Section("Command") {
            TextField("Label", text: $label, prompt: Text("cc.jorviksoftware.my-job"))
            TextField("Command", text: $command, prompt: Text("/usr/local/bin/backup.sh --nightly"))
            Toggle("Also run at login", isOn: $runAtLoad)
            TextField("Output log", text: $stdout, prompt: Text("optional"))
            TextField("Error log", text: $stderr, prompt: Text("optional"))
        }
    }

    private var appSection: some View {
        Section("Application") {
            Picker("App", selection: $appPath) {
                Text("Choose…").tag("")
                ForEach(JobBuilder.installedApps(), id: \.path) { a in Text(a.name).tag(a.path) }
            }
            .onChange(of: appPath) { _, new in
                appName = new.isEmpty ? "" : (new as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            }
        }
    }

    private var weekdayRow: some View { dayRow(selection: $weekdays, emptyLabel: "every day") }

    private func dayRow(selection: Binding<Set<Int>>, emptyLabel: String) -> some View {
        HStack(spacing: 4) {
            Text("Days").frame(width: 44, alignment: .leading)
            ForEach(0..<7, id: \.self) { d in
                Toggle(String(LaunchdJob.weekdayNames[d].prefix(2)), isOn: Binding(
                    get: { selection.wrappedValue.contains(d) },
                    set: { on in if on { selection.wrappedValue.insert(d) } else { selection.wrappedValue.remove(d) } }))
                .toggleStyle(.button).controlSize(.small)
            }
            Text(selection.wrappedValue.isEmpty ? emptyLabel : "").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timeRow(_ title: String, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 44, alignment: .leading)
            Picker("", selection: hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
                .labelsHidden().frame(width: 70)
            Text(":")
            Picker("", selection: minute) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
                .labelsHidden().frame(width: 70)
        }
    }

    // ── load / save ─────────────────────────────────────────────────────────
    private func seedFields() {
        mode = seed.mode
        guard let j = seed.existing else { return }
        label = j.label
        command = j.programArguments.joined(separator: " ")
        runAtLoad = j.runAtLoad
        stdout = j.standardOutPath ?? ""
        stderr = j.standardErrorPath ?? ""
        appName = j.raw["cc.jorviksoftware.Kairos.appName"] as? String ?? ""
        if let s = j.startInterval { kind = .interval; intervalMinutes = max(1, s / 60) }
        if let c = j.calendarIntervals.first {
            kind = .daily
            hour = c["Hour"] ?? 9
            minute = c["Minute"] ?? 0
            weekdays = Set(j.calendarIntervals.compactMap { $0["Weekday"] })
        }
    }

    private var schedule: JobBuilder.Schedule {
        var s = JobBuilder.Schedule()
        s.kind = kind
        s.hour = hour; s.minute = minute; s.weekdays = weekdays
        s.intervalSeconds = max(1, intervalMinutes) * 60
        return s
    }

    private func save() {
        error = nil
        let dir = LaunchdService.agentsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            if mode == .app {
                guard !appPath.isEmpty else { error = "Choose an application."; return }
                let pair = JobBuilder.slug(appName)
                var written: [LaunchdJob] = []

                let launch = JobBuilder.appLaunch(appName: appName, appPath: appPath,
                                                 pairID: pair, schedule: schedule)
                written.append(try write(launch, in: dir))

                var quitSchedule = JobBuilder.Schedule()
                quitSchedule.kind = .daily            // a quit at an interval makes no sense
                quitSchedule.hour = quitHour; quitSchedule.minute = quitMinute
                // Its OWN days. Empty means "whichever day the launch fired", which for a same-day schedule
                // is what you want and for a weekend-long one is not — hence the separate picker.
                quitSchedule.weekdays = quitWeekdays.isEmpty ? weekdays : quitWeekdays
                let quitURL = dir.appendingPathComponent("\(JobBuilder.quitLabel(pair)).plist")
                if quitEnabled {
                    let quit = JobBuilder.appQuit(appName: appName, appPath: appPath, pairID: pair,
                                                 schedule: quitSchedule, force: forceQuit)
                    written.append(try write(quit, in: dir))
                } else if FileManager.default.fileExists(atPath: quitURL.path) {
                    // Turning the quit off must remove the job, not merely stop showing it.
                    if let j = LaunchdJob.load(from: quitURL) { _ = LaunchdService.delete(j) }
                }

                let kaURL = dir.appendingPathComponent("\(JobBuilder.keepAliveLabel(pair)).plist")
                if keepAlive {
                    let ka = JobBuilder.appKeepAlive(appName: appName, appPath: appPath,
                                                    pairID: pair, everyMinutes: keepAliveMinutes)
                    written.append(try write(ka, in: dir))
                } else if FileManager.default.fileExists(atPath: kaURL.path) {
                    if let j = LaunchdJob.load(from: kaURL) { _ = LaunchdService.delete(j) }
                }
                for j in written { if let e = LaunchdService.reload(j) { error = e } }
            } else {
                guard !label.isEmpty else { error = "A label is required."; return }
                let args = command.split(separator: " ").map(String.init)
                guard !args.isEmpty else { error = "A command is required."; return }
                let d = JobBuilder.command(label: label, arguments: args, schedule: schedule,
                                           runAtLoad: runAtLoad,
                                           stdout: stdout.isEmpty ? nil : stdout,
                                           stderr: stderr.isEmpty ? nil : stderr)
                let job = try write(d, in: dir)
                if let e = LaunchdService.reload(job) { error = e }
            }
        } catch { self.error = error.localizedDescription; return }

        if error == nil { onSave(); dismiss() }
    }

    private func write(_ dict: [String: Any], in dir: URL) throws -> LaunchdJob {
        let lbl = dict["Label"] as! String
        let url = dir.appendingPathComponent("\(lbl).plist")
        let job = LaunchdJob(label: lbl, url: url, raw: dict)
        try job.write()
        return job
    }
}
