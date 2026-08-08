# Kairos

A front end for launchd's user agents. Free, open source, native, no telemetry.

*Kairos* — Καιρός — is the Greek god of the **opportune moment**: not time as duration, which is Chronos,
but the right instant to act. He was shown as a youth with a long forelock and a bald back of the head. You
catch him as he comes, or not at all.

---

## Why

macOS already has an excellent scheduler. `launchd` runs everything on the system, survives reboots, handles
missed runs, and needs no third-party daemon sitting in your menu bar. What it does not have is any way to
see what it is doing.

Answering *"is this job loaded, has it ever actually run, and did it fail?"* means
`launchctl print gui/501/com.example.thing` and reading a hundred lines of output. Writing a new job means
hand-authoring XML and knowing that `Weekday` counts Sunday as both 0 and 7.

The good GUIs for this — LaunchControl, Lingon — are paid and closed. Kairos is neither.

## What it shows

For every agent in `~/Library/LaunchAgents`:

- **the schedule, in English** — *"18:30 on Monday, Wednesday, Friday"*, not `Minute => 30, Hour => 18`
- **four states, not two** — loaded, disabled, running, failed. Most tools show one on/off switch, which
  hides the difference between *off* and *off for a reason you forgot months ago*
- **how many times it has run**, because a job that has never once fired looks exactly like a healthy idle
  one until you see the count is zero
- **its last exit code** — the only failure signal launchd reliably gives you, and easy to miss, since a job
  that exits non-zero simply is not there any more
- **its own output**, tailed from wherever it writes

Load, unload, enable, disable, run now, edit, reveal, delete.

## The trap it exists to surface

`launchctl disable` writes to a database that is **separate from the plist**, and survives deleting the file.
A job can be disabled by a command you ran months ago, and nothing in `~/Library/LaunchAgents` will tell you.
You load it, launchd says nothing, and it never runs.

Kairos reads that database separately and shows *Disabled* as its own state, with the explanation attached.

## Scheduling an app

The second creation mode, and the one no generic plist editor has. Pick an app, pick a launch time and a
quit time. Kairos writes both jobs and presents them as one thing.

Two details it gets right on your behalf:

- **Launching uses `open -a`**, not the binary inside the bundle. `open` hands the launch to the window
  server in your session, which is what actually makes a GUI app appear. Running
  `Foo.app/Contents/MacOS/Foo` from launchd gets you a process with no session and often no window.
- **Quitting sends an AppleEvent**, not a kill — so the app can save and close cleanly. That also means it
  can be **refused**: an app with an unsaved document will put up a dialog and stay open. Kairos says so at
  the point you choose, and offers a force fallback as an explicit decision rather than a default. Silently
  destroying unsaved work to keep to a schedule is the wrong trade.

## Scope

**User agents only.** Not `/Library/LaunchDaemons`.

That is deliberate, and the second reason is the decisive one. Editing system daemons needs a privileged
helper, which is a large security surface for a small utility — but more importantly, **a LaunchDaemon
cannot launch a GUI application into your login session at all**, so for the thing this app exists to make
easy, daemons are the wrong tool anyway.

## Building

    gmake build        # compile
    gmake release      # signed, notarised, packaged (see PerpetualBeta/jorvik-release)

SPM, macOS 14+, universal. Sparkle is vendored at the project root and embedded by `release.mk`; it is not
committed.

Kairos is **not sandboxed**, necessarily: it manages files outside its container and shells out to
`launchctl`. Developer ID signed and notarised, distributed outside the App Store.
