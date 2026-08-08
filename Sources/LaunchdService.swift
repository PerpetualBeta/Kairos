import Foundation

/// Everything this app knows about talking to launchd.
///
/// MODERN VERBS ONLY. Almost every example online still shows `launchctl load` / `unload`, which have been
/// legacy since macOS 10.10 and behave differently from what people expect. This uses the domain-target
/// forms throughout:
///
///     bootstrap gui/<uid> <plist>     load it
///     bootout    gui/<uid>/<label>    unload it
///     kickstart -k gui/<uid>/<label>  run it now
///     enable  / disable               persistent, and NOT the same as loaded
///     print                           what launchd actually thinks
///
/// THE TRAP THIS APP EXISTS TO SURFACE: `disable` writes to a database that is *separate from the plist*
/// and survives deleting the file. A job can be disabled by a `launchctl disable` you ran months ago, and
/// nothing in `~/Library/LaunchAgents` will tell you. That is why `disabledLabels()` is read separately and
/// shown as its own state rather than folded into "loaded".
enum LaunchdService {

    static var agentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var domain: String { "gui/\(getuid())" }

    // ── running launchctl ───────────────────────────────────────────────────
    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "could not run launchctl: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // ── reading ─────────────────────────────────────────────────────────────
    static func jobs() -> [LaunchdJob] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: agentsDirectory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".plist") }
            .compactMap { LaunchdJob.load(from: agentsDirectory.appendingPathComponent($0)) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Labels currently in launchd's *disabled* database. See the note on this type.
    static func disabledLabels() -> Set<String> {
        let r = run(["print-disabled", domain])
        var out = Set<String>()
        for line in r.out.split(separator: "\n") {
            // Verified against real output, which is:   "com.example.thing" => enabled
            // NOT `=> true`, which an earlier version of this checked for and which never matches. It
            // happened to behave because the other half of the test caught `=> disabled` — a parser that
            // is right by accident is one edit away from being wrong.
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix("=> disabled"), let name = t.split(separator: "\"").dropFirst().first
            else { continue }
            out.insert(String(name))
        }
        return out
    }

    static func status(of label: String, disabled: Set<String>) -> JobStatus {
        var s = JobStatus()
        s.disabled = disabled.contains(label)
        let r = run(["print", "\(domain)/\(label)"])
        guard r.status == 0 else { return s }        // not bootstrapped → not loaded
        s.loaded = true
        for line in r.out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = ") { s.pid = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("last exit code = ") {
                let v = t.dropFirst(17).trimmingCharacters(in: .whitespaces)
                s.lastExitStatus = Int(v)            // can read "(never exited)", which is nil and correct
            }
            // `runs` answers the question a status light cannot: has this job EVER fired? A schedule that
            // has never once run looks identical to a healthy idle one until you see the count is zero.
            if t.hasPrefix("runs = ") { s.runs = Int(t.dropFirst(7).trimmingCharacters(in: .whitespaces)) }
        }
        return s
    }

    // ── writing ─────────────────────────────────────────────────────────────
    static func bootstrap(_ job: LaunchdJob) -> String? { fail(run(["bootstrap", domain, job.url.path])) }
    static func bootout(_ job: LaunchdJob) -> String? { fail(run(["bootout", "\(domain)/\(job.label)"])) }
    static func enable(_ job: LaunchdJob) -> String? { fail(run(["enable", "\(domain)/\(job.label)"])) }
    static func disable(_ job: LaunchdJob) -> String? { fail(run(["disable", "\(domain)/\(job.label)"])) }

    /// Run it now. `-k` kills a running copy first, so "run now" means the same thing whether or not it
    /// happens to be mid-run — otherwise the button does two different things depending on timing.
    static func runNow(_ job: LaunchdJob) -> String? {
        fail(run(["kickstart", "-k", "\(domain)/\(job.label)"]))
    }

    /// Reload after an edit. Bootout can legitimately fail (it may not be loaded), so its result is ignored
    /// and only the bootstrap is reported — the alternative is an error dialog every time you edit an
    /// unloaded job.
    static func reload(_ job: LaunchdJob) -> String? {
        _ = run(["bootout", "\(domain)/\(job.label)"])
        return bootstrap(job)
    }

    static func delete(_ job: LaunchdJob) -> String? {
        _ = run(["bootout", "\(domain)/\(job.label)"])
        do { try FileManager.default.removeItem(at: job.url) } catch { return error.localizedDescription }
        return nil
    }

    private static func fail(_ r: (status: Int32, out: String)) -> String? {
        guard r.status != 0 else { return nil }
        let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "launchctl exited \(r.status)" : msg
    }

    // ── the log a job writes ────────────────────────────────────────────────
    static func tail(_ path: String?, lines: Int = 200) -> String {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        // Read the last 64 KB rather than the whole file: these logs grow unbounded and a job that has been
        // running for a year should not stall the UI.
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
