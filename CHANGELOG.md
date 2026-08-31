# Changelog

Notable changes. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semver](https://semver.org/).

## [Unreleased]

- **Codex session reminders now match Claude's independent controls.** Accounts that report a
  session window can choose its lead time, minimum remaining quota, queue condition and repeat
  policy without sharing the Codex weekly or Claude rules. The new rule stays off on upgrade, and
  weekly-only plans explain that the window is unavailable instead of presenting missing data as
  a reset-time failure. Delivered and snoozed reminders now retain their provider as well as their
  window, fixing once-per-window fingerprints that previously fell back to Claude's rule.

- **Side Notch is available as an opt-in Alpha surface.** Settings → General can place a tiny,
  focus-free handle at the right edge of the display under the pointer. Hover expands it into one
  animated double ring per enabled provider; hovering a ring opens both quota rows and reset times,
  while a click pins and releases the card. It follows Spaces and full-screen apps, honours Reduce
  Motion, and collapses 400ms after the pointer leaves the combined surface. Ring order comes from
  the freely configured menu-bar ring slots but is regrouped per provider. Colours can follow the
  menu bar or start from a copied palette and then remain independent. The feature is off on every
  existing install, and stale or absent readings show empty neutral tracks rather than 0%. The
  Alpha's first polish pass keeps the collapsed mark small but gives it a wider invisible hover
  target and a subtle edge glint, thins and separates the nested arcs, highlights the selected
  provider, and joins the denser detail card to its rail cell with a short pointer. The menu-bar
  colour controls now sit before Side Notch, where its **Follow menu bar** choice can be understood.
  People who want Side Notch alone can hide the complete menu bar item; Tokenmax refuses to hide
  both surfaces, starts its background coordinators independently of the status item, and offers
  Settings, restore, refresh and quit from Side Notch's own context menu. Settings is now a native
  macOS scene, so opening it no longer depends on the hidden status item. Its detail card carries the
  provider context that was previously exclusive to the popover: plan and freshness, the pace
  marker, reserve or deficit, projected empty time, each reminder's state and unexpired Codex reset
  credits. The card grows for the information and windows that actually exist, so weekly-only plans
  do not leave a blank session behind.

- **Escalation colours for the menu bar meters.** Settings → General → Colour can switch the icon
  from **Monochrome** to **Escalating**: up to three levels, each with a colour and a trigger that
  is either a percentage or that window's own reminder firing. Applies to bars and rings alike.
  Monochrome stays the default and draws exactly what it drew before — a template image macOS tints
  to the menu bar — and the base colour defaults to Neutral so the icon stays a template until a
  level is actually reached. A percentage level outranks the "good time to spend" highlight; a
  reminder level yields to it; stale readings are never coloured.

- **A double-ring menu bar icon.** Settings → General → Menu bar icon now offers a second shape
  beside the bars: nested arcs, an outer one enclosing an inner one, two per ring. A session runs
  inside a week, so putting the week on the outer arc draws that relationship instead of flattening
  it into two equal rows — and two rings hold all four quotas at once, where bars stop at three.
  Every arc is assignable by the same drag as the bars, so a ring is not tied to one provider.
  Bars stay the default and nothing changes for an existing install. Two rings take about 35pt of
  menu bar where two bars take 20; a single ring takes 16, less than the bars it replaces. The
  display-mode labels are now "Icon only" and "Icon + time remaining", since they no longer only
  describe bars.

- **Celebrate confirmed quota resets.** An optional, click-through confetti shower can mark new
  quota windows. Choose every reset or individual Claude Code/Codex session and weekly events;
  stale data, reset-time jitter, and quiet hours stay silent. A **Preview Confetti** button in
  Settings exercises the real overlay without waiting for a reset, and the animation now keeps
  advancing while another app is active.

## [0.1.12] - 2026-08-28

### Fixed

- **A rejected token no longer costs a keychain read every five minutes.** When
  the quota endpoint refused the saved credential, Tokenmax dropped it and read
  the keychain again on the next tick — but until Claude Code writes a new
  token, the item still holds the one that was just refused, so the read could
  only return the same credential and, for anyone who answered the consent
  dialog with *Allow*, raise another dialog. Measured across a fortnight of one
  user's logs, 64 of 176 reads were this loop, stacking dialogs minutes apart
  while the app appeared to be idle. Tokenmax now notes when Claude Code last
  wrote the item and waits for that timestamp to move before reading again —
  the item's modification date is an attribute, not the secret, so watching it
  needs no consent and raises no dialog. The wait ends by itself the moment
  Claude Code renews the token; **Refresh** ends it early, and a relaunch
  clears it. While it holds, the popover reports the same "awaiting renewal"
  state the rejection already produced and keeps showing the last good reading.

- **A token past its expiry no longer forces a keychain read either.** Tokenmax
  used to drop any credential past its own expiry timestamp and go back to the
  keychain, assuming a newer one had been stored by then. When Claude Code has
  not written the item since, it has not — so the read returned the identical
  token and could cost a consent dialog for it. Tokenmax now serves the token
  it already has and lets the endpoint be the judge, which is what the expiry
  timestamp was always treated as: a hint, never a reason to refuse to try. If
  the endpoint does reject it, the wait above takes over. Both rules are the
  same one: go back to the keychain when, and only when, Claude Code has
  written to it.

## [0.1.11] - 2026-08-28

### Added

- **Codex banked reset availability now appears in the popover.** When Codex
  reports promotional rate-limit resets, Tokenmax shows the available count and
  nearest expiry below the Codex meters. It remains read-only: redeeming a reset
  changes account allowance and stays in Codex, where the offer can be reviewed
  and confirmed.

- **Reset countdowns now show the local clock time too.** Next to "Resets in
  1h 56m" the popover names the actual time that lands at, in your Mac's
  timezone and hour format. The session window shows just the time; the
  weekly window shows weekday plus time, since that reset is days out rather
  than hours.

## [0.1.10] - 2026-08-26

### Fixed

- **Claude's credential-rejection state now says what is actually happening.**
  A Claude Code conversation can continue on its existing connection while the
  older credential in the keychain is rejected by the quota endpoint. The
  popover now names that split instead of claiming that simply running Claude
  Code will fix it, retains any live status-line reading, and offers **Open
  Terminal + Copy Login** as a concrete recovery when Claude Code does not
  renew the saved credential on its own.

- **Codex quota and model reads work with Codex CLI 0.149 and later.** The CLI
  no longer accepts the old `-a untrusted` approval policy, which made its
  read-only App Server exit before answering and left Tokenmax timing out.
  Tokenmax now uses the valid `never` policy for its read-only query, which
  executes no work and has no approval to request.

- **The Keychain troubleshooting log path now points at the actual file.** The
  direct path omitted the `logs` directory, sending a person investigating a
  prompt to a file that did not exist.

## [0.1.9] - 2026-08-21

### Added

- **A status-line-only data source, for people who want the keychain dialog
  gone entirely.** **Settings → Data Source** now chooses where the Claude
  numbers come from. The default remains the keychain-backed usage endpoint —
  accurate, pollable, and the only source that carries the per-model weeklies,
  the plan name and the usage-credit flag. The new **Status line only** mode
  reads nothing but the file the statusline shim writes, so the keychain is
  never touched and macOS never asks — not once, not per version. The trade is
  stated rather than hidden: readings update only while a Claude Code session
  is answering, and because a mode that cannot poll cannot confirm what an
  unattended run just spent, the session opener and automatic task runs pause
  under it, each naming the reason in Settings. Running a task by hand still
  works. The model-catalog fetch pauses too — it uses the same keychain token,
  and fetching it would reintroduce the dialog the mode exists to remove.

- **Every keychain read is logged with the evidence needed to diagnose it.**
  The log records each read's trigger, outcome and duration — a fast read is
  `silent`, while a slow one `likely waited on a consent dialog` — plus the
  item's last modification time and, at launch, the binary's cdhash that
  grants are keyed to. Timing is evidence rather than proof, so the wording
  stays honest while making "the prompt keeps appearing" answerable from
  `make logs` instead of memory.

### Fixed

- **Denying the keychain prompt no longer brings it back every five minutes.**
  A *Deny* used to be retried on the next refresh tick, indefinitely — the app
  arguing with an answer the user had already given, and the substance of the
  "prompt appears randomly several times a day" reports. A denial is now
  remembered for the rest of the launch: the popover shows **Keychain access
  denied**, and clicking **Refresh** there is the one thing that asks again.
  Only an answered dialog is remembered — a keychain that was merely locked at
  the moment of a background tick keeps being retried, so a locked screen can
  never switch monitoring off.

- **Forced background verification no longer overrides a Keychain denial.**
  The opener and automatic queue both force fresh network readings, but that
  internal meaning of "manual" briefly also cleared a remembered *Deny* and
  could reopen the dialog without a click. Retrying consent is now a separate
  signal carried only by user refresh controls.

- **Concurrent credential callers now share the in-flight Keychain read.** A
  usage refresh and model-catalog fetch arriving together could both observe an
  empty cache and raise duplicate dialogs. One caller now owns the read while
  the others wait for its result.

## [0.1.8] - 2026-08-09

### Added

- **Installable with Homebrew, this time for real.**
  `brew install --cask danieldrinhausen/tap/tokenmax` installs and
  `brew upgrade --cask tokenmax` follows releases, from a
  [tap of its own](https://github.com/danieldrinhausen/homebrew-tap) that polls
  this repository hourly and bumps itself when a release appears. The download is
  the same signed, unnotarized image, so the one-time **Open Anyway** remains —
  Homebrew quarantines what it fetches exactly as a browser does.

  0.1.6 and 0.1.7 documented this command against a tap that had not been
  created, so it could only fail; that is why it was withdrawn between the two
  releases. The tap now exists, is public, and was verified end to end before
  this sentence was written.

### Fixed

- **The keychain dialog no longer returns every refresh.** The macOS prompt for
  `Claude Code-credentials` offers *Allow* as well as *Always Allow*, and only
  *Always Allow* records a grant. Every refresh tick used to issue its own
  keychain read — every 60s with the popover open, every 300s behind it, twice
  over when the token looked expired, and once more for the model catalog — so
  anyone who took the middle button got a dialog a minute for as long as the app
  ran. That was the substance of the first round of outside feedback.

  Credentials are now held in memory by a single shared `ClaudeCredentialCache`,
  so the worst case is one prompt per launch rather than one per refresh.
  Successes only are cached: a denial or a missing item is retried on the next
  call, since neither is a decision worth remembering. Nothing reaches disk, no
  token is handed out past its own `expiresAt`, and a 401 from the usage
  endpoint drops the cache so a rotated token is picked up on the next tick.

  This caps the annoyance; it does not remove the prompt. Because the bundle is
  self-signed it carries no Team Identifier, so macOS keys the grant to the
  build's code hash and a new binary is a new program — one prompt per version
  installed. [Troubleshooting](docs/TROUBLESHOOTING.md#the-keychain-prompt-comes-back-every-time)
  now explains which button to press and what would actually end it.

## [0.1.7] - 2026-08-07

### Added

- **A task can be run by Codex.** The queue could already execute a Codex task —
  the runner, the sandbox policy and the reasoning setting were all there — but
  nothing in the app could create one, so every task was Claude's. The editor
  now has a **Provider** picker, and Settings chooses which provider new tasks
  start on. A task carries both providers' settings at once, so switching the
  picker never loses what you set on the other side.
- **Codex tasks can run automatically.** Under **Settings → Queue automation →
  Codex**, behind a switch of its own — trusting one agent to run unattended is
  not the same decision as trusting two, so it stays off through an upgrade.
  Tokenmax spends whichever Codex window is about to expire: the session window
  on plans that report one, the weekly window on plans that do not, which is
  where a Plus account gets its run. Codex carries its own lead time and
  per-window allowances for that reason — against a seven-day window, "one task
  per window" means one a week. Everything else is shared with Claude, including
  appointments at a specific date and time.
- **A mixed queue says which agent runs what.** Cards carry a provider badge
  once the queue actually holds both, and the search row gains a provider
  filter. Neither appears on a queue that only ever uses one.
- **The Codex model is a list rather than a typed-in id.** Codex reports its own
  models over the App Server, including which reasoning levels each one accepts —
  they genuinely differ per model. Tokenmax now asks, caches the answer, and
  refreshes it at most daily, the same way it already handles Anthropic's model
  list. A model released after your copy of Tokenmax appears on its own, and
  **Other…** still accepts anything typed by hand.

### Fixed

- **A failed Codex run now says why it failed.** Tokenmax listened for a
  `turn/failed` notification the App Server protocol does not have, so a failure
  arrived as a bare status with no reason attached. The reason travels inside
  `turn/completed`. Found by the new Codex drift checks in `make doctor`, which
  now cover the flags, sandbox and approval values, and every JSON-RPC method
  name — the last checked against the protocol schema the installed CLI
  generates, so it cannot go stale against a copy checked into this repository.

## [0.1.6] - 2026-08-07

### Added

- **A task can be given a time to run.** The queue's schedule answers "spend
  what is about to expire", which is the wrong question for "I am away on Friday
  afternoon, use the week's leftover allowance then". A task can now carry a
  specific date and time in its editor. At that moment it runs, wherever the
  session happens to be in its cycle — and if no session is open, starting the
  task opens one.

  Only the timing is overridden. The session and weekly quota floors, quiet
  hours, the account gates and the task's own limits all still apply, so an
  appointment reaches no further into your allowance than the same task would
  have on its own. It also does not consume the per-session task and runtime
  allowances, which budget the opportunistic burn rather than work you asked for
  by name.

  It runs once — the time is cleared when the run starts — and it expires if it
  is missed, since nothing evaluates while the Mac is asleep and a task started
  hours late runs against a project that has moved on. The grace period is
  configurable under **Settings → Queue Automation → Timing**.

- **The per-task spend limit takes any amount.** It was a six-entry dropdown
  topping out at $5.00, which was never a considered ceiling but read as one.
  Presets now reach $100 and an **Other…** field takes anything in between —
  deliberately burning a plan's leftover allowance in one afternoon is two
  orders of magnitude away from the ten-cent chore the old list was sized
  around. A default for new tasks joins the model and thinking grade under
  **New task defaults**.

- **A task can stop itself when the quota runs out.** Past the plan allowance
  Claude Code does not stop — it keeps working and bills usage credits. The
  quota thresholds already keep a run well short of that line; **Stop if the
  quota runs out**, on by default, ends a run already under way if a window
  empties anyway. It reacts within a usage refresh rather than instantly, so it
  is the net rather than the guard.

  **Never run when usage credits could be charged** is a third, categorical
  option under **Safety**, off by default. Having credits enabled is a normal
  thing to have and says nothing about proximity to the line. Switch it on if
  you would rather not depend on the reported percentages being right.

### Changed

- **Two execution modes that never did anything are gone.** "Ask before running"
  and "Allow once during the current session" sat between "Manual only" and
  "Always allow automatic execution" and were read by no code: all three
  non-automatic values behaved identically, while the editor promised a
  notification and a one-off run that never happened. Existing tasks set to
  either now read as **Manual only**, which is how they already behaved.

  "Ask before running" still exists queue-wide under **Settings → Queue
  Automation → Mode**, where it is implemented and does notify.

- **A spend limit outside the preset list no longer disappears.** Such a value
  bound to a dropdown with no matching entry, so it rendered blank and was
  silently overwritten the first time the control was touched. It now shows up
  in the **Other…** field.

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
