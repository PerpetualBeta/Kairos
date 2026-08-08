import SwiftUI
import AppKit

@Observable
final class JobStore {
    var jobs: [LaunchdJob] = []
    var statuses: [String: JobStatus] = [:]
    var lastError: String?

    func reload() {
        jobs = LaunchdService.jobs()
        let disabled = LaunchdService.disabledLabels()
        var s: [String: JobStatus] = [:]
        for j in jobs { s[j.label] = LaunchdService.status(of: j.label, disabled: disabled) }
        statuses = s
    }

    func status(_ job: LaunchdJob) -> JobStatus { statuses[job.label] ?? JobStatus() }

    func perform(_ label: String, _ action: () -> String?) {
        lastError = action().map { "\(label): \($0)" }
        reload()
    }
}

struct ContentView: View {
    @State private var store = JobStore()
    @State private var selection: LaunchdJob?
    @State private var editing: EditorSeed?

    var body: some View {
        NavigationSplitView {
            List(store.jobs, selection: $selection) { job in
                JobRow(job: job, status: store.status(job)).tag(job)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if store.jobs.isEmpty {
                    ContentUnavailableView("No user agents",
                                           systemImage: "clock.badge.questionmark",
                                           description: Text("Nothing in ~/Library/LaunchAgents yet."))
                }
            }
        } detail: {
            if let job = selection, let live = store.jobs.first(where: { $0.label == job.label }) {
                JobDetail(job: live, status: store.status(live), store: store, editing: $editing)
            } else {
                ContentUnavailableView("Select an agent", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Run a Command…") { editing = EditorSeed(mode: .command) }
                    Button("Schedule an App…") { editing = EditorSeed(mode: .app) }
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
                        if job.isAppSchedule, let pair = job.kairosPair {
                            badge(JobBuilder.windowIsOpen(pair) ? "Window open" : "Window closed",
                                  JobBuilder.windowIsOpen(pair) ? .blue : .secondary)
                        }
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

                if job.isAppSchedule, let pair = job.kairosPair {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            if JobBuilder.windowIsOpen(pair) {
                                Button("Close Window Now") {
                                    store.perform(job.label) { JobBuilder.closeWindow(pair) }
                                }
                            } else {
                                Button("Open Window Now") {
                                    store.perform(job.label) { JobBuilder.openWindow(pair) }
                                }
                            }
                            Spacer()
                        }
                        Text(JobBuilder.windowIsOpen(pair)
                             ? "\(job.kairosAppName ?? "This app") is due to be running, so the guard will restart it if it stops. Closing the window stops that — it does not quit the app."
                             : "Not due to be running. Opening the window starts the schedule early; the guard will launch it at the next check.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }

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
