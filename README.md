# Kairos

A front end for launchd's user agents. Free, open source, native, no telemetry.

*Kairos* — Καιρός — is the Greek god of the **opportune moment**: not time as duration, which is Chronos,
but the right instant to act. He was shown as a youth with a long forelock and a bald back of the head. You
catch him as he comes, or not at all.

---

## Requirements

macOS 14 (Sonoma) or later. Universal binary — Apple silicon and Intel.

No permissions are required: Kairos reads and writes your own `~/Library/LaunchAgents` and runs
`/bin/launchctl`.

## Installation

Two formats on every release, both signed and notarised:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/Kairos/releases/latest/download/Kairos.pkg)** —
  recommended for a first install. macOS places the app in `/Applications` without quarantine or App
  Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/Kairos/releases/latest)** — unzip and drag
  `Kairos.app` to your Applications folder.

Or with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/kairos
```

Updates arrive through [Sparkle](https://sparkle-project.org): Kairos checks daily in the background, and
**Check for Updates…** asks on demand.

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

The launch and the quit have **independent days**, so a schedule can span them: launch Friday at 16:00,
quit Monday at 09:00, and the app runs across the whole weekend.

An app schedule shows **four states**, from two independent facts — whether it is *due* to run, and whether
the app *is* running:

| | due | not due |
|---|---|---|
| **running** | Running | Running, outside its schedule |
| **not running** | **Should be running — it is not** | Next run Mon 09:00 |

There is a fifth: **This run was ended early** — inside the hours, but you stopped this run by hand, so
nothing will restart it until the next launch time.

Only the orange one means anything is wrong, and it is the reason for showing the two facts rather than one.
Telling you an app *should* be running is guesswork when the answer is available for the asking; telling you
it should be and **is not** is the thing worth interrupting you for. The running state is read from
`NSWorkspace` when an app starts or stops, so the badge is current rather than as-of-the-last-refresh.

**End Early** and **Start Early** sit beside it. Ending early is what makes quitting a kept-alive app by hand
actually stick; without it the guard restores the app at the next check, which is correct and maddening.
Ending early does not quit the app, and the pane says so.

"Due" is computed from the launch and quit times themselves, not from whether a run happens to be open.
Those differ for every schedule between the moment you create it and its first launch time coming round —
the marker below is written *by* the launch job, so until that job has fired even once there is nothing on
disk. Kairos used to call such an app unscheduled while it sat squarely inside its hours, and the guard,
gating on the same absent marker, would not have restarted it if it had crashed. Kairos now opens the run
itself for any schedule that is inside its window and has never launched.

**Keeping it running** is offered there too, and it is deliberately *not* launchd's `KeepAlive`. That key on
the launch job would watch `open` — which exits the instant the app is up — and relaunch it in a tight loop
forever. "Keep this process alive" and "keep that application running" are different requests, and only the
second is ever what anyone means. Instead the launch job opens a **window**: a marker file saying the app is
due to be running. The quit job clears it. A small guard checks on an interval, and restarts the app only if
the marker is present and the app is not. No clock arithmetic, survives reboots, and multi-day schedules fall
out for free.

Two details it gets right on your behalf:

- **Launching uses `open -a`**, not the binary inside the bundle. `open` hands the launch to the window
  server in your session, which is what actually makes a GUI app appear. Running
  `Foo.app/Contents/MacOS/Foo` from launchd gets you a process with no session and often no window.
- **Quitting sends an AppleEvent**, not a kill — so the app can save and close cleanly. That also means it
  can be **refused**: an app with an unsaved document will put up a dialog and stay open. Kairos says so at
  the point you choose, and offers a force fallback as an explicit decision rather than a default. Silently
  destroying unsaved work to keep to a schedule is the wrong trade.

## The Dock icon tells the time

While Kairos is running, its Dock icon is the real clock — redrawn on the minute, aligned to the minute
boundary so it changes when the clock does rather than up to 59 seconds late.

Only while it is running: `applicationIconImage` belongs to the running application, so Finder and a quit
app's Dock tile still show the static icon. Apple's own Clock behaves the same way, for the same reason.

Per minute, not per second — a second hand is a few pixels at Dock size and would cost a redraw every second
to say nothing. The drawing is shared with the build-time icon generator rather than copied, so the two
cannot drift.

## Scope

**User agents only.** Not `/Library/LaunchDaemons`.

That is deliberate, and the second reason is the decisive one. Editing system daemons needs a privileged
helper, which is a large security surface for a small utility — but more importantly, **a LaunchDaemon
cannot launch a GUI application into your login session at all**, so for the thing this app exists to make
easy, daemons are the wrong tool anyway.

## Architecture

| Component | Purpose |
|-----------|---------|
| `LaunchdService.swift` | Everything that talks to `launchctl` — modern domain-target verbs, status parsing, the disabled database |
| `LaunchdJob.swift` | One plist, plus enough understanding of it to describe its schedule in English |
| `AppSchedule.swift` | Groups the two or three jobs that implement a scheduled app into the one thing the user made |
| `JobBuilder.swift` | Writes the plists — command mode, and the launch/quit/guard trio for an app |
| `JobEditor.swift` | The single configuration sheet, for both modes |
| `ContentView.swift` | The two sidebar views, and the detail panes |
| `IconRenderer.swift` | The clock, drawn — shared by the bundle icon and the live Dock icon |

## Building from Source

Kairos uses Swift Package Manager. No Xcode project is required.

The build includes the shared `release.mk` from
[jorvik-release](https://github.com/PerpetualBeta/jorvik-release), which must be checked out **beside** this
repository — hence both clones below. macOS ships GNU Make 3.81, which cannot run these recipes, so the
commands use `gmake` from [Homebrew](https://brew.sh)'s `make`.

```sh
brew install make                                              # provides gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git  # sibling checkout, required
git clone https://github.com/PerpetualBeta/Kairos.git
cd Kairos
gmake build
open .build/Kairos.app
```

`gmake icon` regenerates the app icon; `gmake release` produces a signed, notarised build.

Kairos is **not sandboxed**, necessarily: it manages files outside its container and shells out to
`launchctl`. Developer ID signed and notarised, distributed outside the App Store.

## Permissions

- **None required.** Kairos reads and writes your own `~/Library/LaunchAgents` and runs `/bin/launchctl`.
- macOS raises a **Login Items** notification whenever a launch agent is added. That is the system telling
  you a background item appeared, and it will happen every time you create a schedule.

## Other Jorvik tools

- **[QuitProtect](https://jorviksoftware.cc/utilities/quitprotect)** — the other half of the same problem.
  Kairos decides *when* an app runs; QuitProtect stops a careless ⌘Q ending it early.
- **[Lookout](https://jorviksoftware.cc/utilities/lookout)** — watches GitHub for the things a schedule
  cannot predict: review requests, failing CI, notifications.
- **[CalendarUpcoming](https://jorviksoftware.cc/utilities/calendarupcoming)** — the same instinct applied to
  a calendar rather than to launchd.

The whole catalogue is at [jorviksoftware.cc](https://jorviksoftware.cc/).

---

Kairos is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider
[buying me a coffee](https://jorviksoftware.cc/donate).
