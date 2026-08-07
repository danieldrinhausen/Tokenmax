# Changelog

Notable changes. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semver](https://semver.org/).

## [Unreleased]

## [0.1.5] - 2026-08-07

### Fixed

- **Codex task processes now have the same lifecycle guarantees as Claude task
  processes.** Tokenmax drains stderr so a noisy command cannot deadlock, caps
  retained output and raw logs, terminates the whole process group on timeout or
  cancellation, and refuses an unreadable working directory before launch.

- **A paid queue run cannot start unless its run record was saved first.** Disk
  errors used to be logged and ignored, which could let a task spend quota
  without leaving the record that prevents it from being repeated after a
  restart. Tokenmax now fails closed, names the suppression in the UI, and
  refuses further runs until the storage problem is fixed and the app restarted.

- **The optional Claude Code statusline integration now works from its normal
  path under Application Support.** The installed command is shell-quoted,
  unrelated lookalike commands are not claimed, and uninstall restores the
  complete statusline configuration Tokenmax displaced instead of deleting it.

## [0.1.4] - 2026-08-06

### Fixed

- **`make test` no longer raises keychain dialogs.** The suite is hosted inside
  the app, so `TokenmaxApp.init()` ran for real during a test run and the
  coordinators it builds read the login keychain. That host is ad-hoc signed
  and cannot satisfy the requirement stored by the installed, certificate-signed
  copy, so macOS asked for consent — twice per run, once per object that reads
  credentials, and unanswerable in the sense that mattered: its cdhash changes
  on every build, so "Always Allow" had nothing stable to attach to. Test runs
  now refuse the real keychain, and a test asserts the refusal.

- **Provider errors now name the provider that failed.** A missing Codex CLI
  used to be reported as "Claude Code is not installed", even when Claude Code
  was installed and working. The shared error now carries the display name of
  the provider that raised it.

## [0.1.3] - 2026-08-06

### Added

- **The running version is visible in the app.** Beside the name in the popover
  header, and in a new **Settings → About** pane with the build number and the
  macOS the app needs. A bug report no longer has to start in Finder.
- **A daily update check.** Tokenmax asks GitHub once a day whether a newer
  release has been published and links to it when there is one. It never
  installs anything itself — deliberately: the alternatives were the project's
  first third-party dependency, or a hand-written self-replacing bundle in an
  app that is signed but not notarized.

  It is the only request Tokenmax makes to a host unrelated to quota, so it has
  a switch in **Settings → About**, and off means no request rather than an
  ignored answer.

## [0.1.2] - 2026-08-06

### Added

- **The menu bar icon answers a right-click.** Settings, Open Queue, Refresh and
  Quit, without opening the popover first. Control-click does the same.

### Changed

- **Settings is a plain button in the popover footer.** It used to share an
  ellipsis menu with Quit, which put the one thing anyone opens repeatedly two
  clicks away. Quit moved to the icon's right-click menu, where macOS menu bar
  apps keep it.

### Fixed

- **Windows opened from the menu bar no longer land behind other apps.** Opening
  Settings or the queue while no Tokenmax window was already up placed the new
  window behind whatever was in front — reliably, not occasionally, since the
  app returns to its no-window state every time the last one closes.

  Two things were wrong. Activation was requested only for the *first* window,
  so a second one never asked at all. And activation alone does not work here:
  macOS 14 made it cooperative, so an app that is not already frontmost is not
  granted focus for asking, and it only becomes eligible after its switch out of
  accessory mode has settled — a moment too late for the window that caused the
  switch. The window is now ordered forward first and the app activated after,
  which is the order that gets both the stacking and the keyboard focus right.

## [0.1.1] - 2026-08-05

### Fixed

- **Each menu bar bar is now coloured by its own window.** Two faults combined
  into one nonsensical icon: a Claude session with 80% remaining was drawn in
  the warning colour, while a Codex week four days from resetting was drawn as
  an opportunity. Neither bar was reporting its own state.

  The "now is a good time to spend this" flag was a single value computed from
  one provider's *session* window and then handed to every bar, so a weekly
  window was lit because a different provider's session was about to reset. It
  is now resolved per bar.

  The warning colour also outranked it. "Already notified" is bookkeeping about
  a notification and says nothing about how much quota is left, so it no longer
  repaints a window the popover is simultaneously calling a good time to spend —
  the two disagreed about the same window in the same second. The warning colour
  keeps the case it was written for: a window that has been announced and is no
  longer an opportunity.
- **Release images are built from the Release configuration.** `make dmg`
  inherited the Debug default, so 0.1.0 shipped an unoptimised build with
  assertions live. It is no longer a flag that can be forgotten.

## [0.1.0] - 2026-08-05

First public release. The **Changed** and **Fixed** entries below describe work
done during pre-release development; there is no earlier version to have
upgraded from.

### Added

- **Codex as a second provider.** Codex quota appears beside Claude Code's, read
  through a short-lived local `codex app-server` over JSON-RPC rather than any
  network endpoint — Tokenmax reuses the login the Codex CLI manages and never
  reads or stores those credentials. A ChatGPT-managed login reports quota
  windows; an API-key login is billed and unmetered, and is labelled as such
  rather than shown as an empty meter. Codex tasks run under a per-task
  read-only or workspace-write sandbox. Either provider can be switched off
  entirely, which hides rather than deletes: its rules, bars and tasks stay on
  disk and return when it is switched back on.
- **A configurable menu bar icon.** Two or three bars, each drawing a quota you
  drag into place, and a countdown that tracks a window chosen independently of
  them — the most useful deadline is not always one the bars have room for.
- **A fetched model catalog.** Models offered in the task editor and the session
  opener come from `GET /v1/models` using the same keychain token as usage, so a
  newly released model appears without updating the app. Refreshed daily, cached
  for offline use, and the built-in aliases still work if the fetch fails.
- **`make doctor`.** Checks the surfaces Tokenmax depends on but does not own:
  that the Claude CLI is where it looks, that every flag it passes still exists
  in `--help`, that the keychain item still has the expected shape, that both
  endpoints still answer, and that the statusline payload still carries the keys
  the shim reads. Costs no quota, and names the source file behind anything it
  finds. Worth running after every Claude Code update.
- **Handbook, troubleshooting and architecture documentation**, plus a security
  policy. The architecture notes include the full map of what breaks when
  upstream changes and how each failure announces itself.

### Fixed

- **A task in a folder macOS protects no longer hangs for its entire runtime
  limit.** Documents, Desktop and Downloads are gated by TCC, but `stat` is not
  — so a folder Tokenmax had no permission to read still reported as existing.
  The task looked eligible, the CLI was spawned, and it then blocked on a
  consent dialog that an unattended run has nobody to answer: no output, no
  transcript, no explanation, and a paused queue fifteen minutes later.
  Readability is now checked with the permission itself, so such a task is
  refused up front (*"Auto-run blocked · no permission to read this folder"*)
  rather than started. The task editor raises the request while the user is
  still there to grant it, and the app declares why it wants the access.

### Changed

- **A stopped run now reports what the CLI actually said.** The stderr tail was
  captured and then discarded for any run Tokenmax killed, leaving a fixed
  sentence in place of the only evidence a timed-out run leaves behind. Timeouts
  now include it, and say explicitly when a run produced no output at all —
  which distinguishes a CLI that never started from a task that was genuinely
  too large.
- **A CLI that rejects Tokenmax's command line is now told apart from a task
  that failed.** A renamed or removed flag used to surface as an ordinary run
  failure, which pointed at the task rather than at the real cause and invited
  retrying something that could never succeed. Such runs are now reported as
  **"Update needed"**, name the offending flag, and pause the queue — the one
  case where pausing is necessary rather than merely defensible, since every
  following task would fail identically.
- **A usage response that has changed shape is no longer reported as "no
  quota".** Every field of the response is optional, which is right for an
  endpoint that may add windows, but it meant a *renamed* window decoded to
  all-nil and read as an empty account. Drift is now distinguished from
  emptiness — an explicitly null window is still just silence — and reported as
  a schema change that needs a Tokenmax update.
- **A transcript that parses no recognisable events now says so in the log.**
  Previously a `stream-json` schema change left the result view blank while the
  run itself succeeded, so nothing anywhere reported a problem. The raw log was
  and remains unaffected.
- **"Skip when usage credits may be charged" now defaults to off.** Credits only
  bill *past* the plan allowance, and the opener only ever runs into a window
  that has just reset with weekly quota above your threshold — a charge cannot
  be reached from there, so the check duplicated a guard that was already doing
  the work while disabling the whole feature for anyone who has credits enabled.
  It remains available: it is categorical where the threshold is numeric, so it
  holds even if the reported percentages are wrong. Existing settings keep
  whatever you already chose.

### Fixed

- **The statusline installer no longer wipes Claude Code's settings.** A
  `~/.claude/settings.json` that failed to parse was read as empty and then
  written back containing only `statusLine`, discarding the user's permissions,
  env, hooks and MCP servers — silently, while reporting success. Install and
  uninstall now stop on an unparseable file, and every write takes a backup
  alongside the original.
- **Run transcripts and the app log are now bounded.** Transcripts in
  `run-logs/` were never deleted, even after their run fell out of the 40-entry
  history, and `tokenmax.log` was append-only with no ceiling. Both hold prompt
  text and working directory paths. Orphaned transcripts are swept whenever
  queue state is saved, and the log rotates at 1 MB keeping one generation.
- **The opener now checks the weekly allowance of the model it will actually
  run.** Only the plan-wide weekly figure was consulted, so with the model set
  to Sonnet a spent `seven_day_sonnet` allowance was waved through while the
  shared week still looked healthy — the one case where running could genuinely
  be billed. Reported as its own skip reason.

- **Session opener no longer deadlocks on an expired token.** The opener refused
  to run on stale data, but the staleness was an expired Claude Code access
  token — which only a Claude Code run renews, and the opener *is* a Claude Code
  run. It now proceeds when that is the cause and the last good reading is under
  five hours old; every spending guard still applies to that reading.
- **A running window no longer burns its cycle's forced refresh.** A live
  window's reset time is in the future, but the guards were ordered so it
  reported as "waiting for fresh data", and the one backoff-bypassing refresh a
  cycle is allowed got spent up to hours before the window ended. Guards now run
  in dependency order: persisted state and clock first, then staleness, then
  anything reading the last quota figures.

## [0.1.0]

First release. Menubar meters for the Claude Code session and weekly windows,
reset countdown, pace projection, reminders before a window resets, a local
prompt queue with unattended runs, and the session opener.
