# Troubleshooting

Symptoms first. Each entry says what you would see, what causes it, and what to
do about it.

**Before anything else**, two commands answer most questions:

```
make doctor    # checks everything Tokenmax depends on but does not own
make logs      # tail the log; every decision is recorded with its reason
```

`make doctor` is the faster of the two. It verifies the Claude CLI is where
Tokenmax looks for it, that every command-line flag Tokenmax passes still exists,
that the keychain item still has the shape it expects, that both endpoints still
answer, and that the statusline payload still carries the keys the shim reads.
Anything it reports as a failure names the source file that needs changing.

---

## Installing and launching

### I hid the menu bar item and cannot find Settings

Right-click the Side Notch handle or its expanded rail and choose
**Settings…**. The same menu can restore **Show Menu Bar Item**. Tokenmax does
not allow both Side Notch and the menu bar item to be switched off together, so
that recovery path remains on screen. Choosing Settings raises the existing
window as well as opening a new one; check the current Space rather than hunting
behind another app.

### "Apple could not verify Tokenmax is free of malware"

Expected. The app is signed but not notarized — notarization requires a paid
Apple Developer account.

**System Settings → Privacy & Security**, scroll to the message about Tokenmax,
click **Open Anyway**, confirm. macOS remembers the choice for that copy.

A newly downloaded version arrives freshly quarantined and needs the same
one-time confirmation. Terminal equivalent:

```
xattr -dr com.apple.quarantine /Applications/Tokenmax.app
```

### The keychain prompt comes back every time

**When the prompt is expected, and when it is not.** For someone who answers
**Always Allow**, these are the usual cases. Claude Code owns the item and its
storage behaviour has changed between versions, so a prompt outside the table
is worth reporting with the log evidence below, not declaring impossible:

| Moment | Prompt expected? | Why |
|---|---|---|
| First launch ever | **Yes, once** | macOS has never seen this app read the item |
| After installing a new version | **Yes, once** | The grant is keyed to the binary's code hash; a new version is a new hash |
| After rebuilding it yourself | **Yes, once per build** | Same reason — every compile produces a new hash |
| Starting the app (same binary and item) | No | The recorded grant still matches both |
| Claude Code updating credentials in place | Normally no | An in-place data update should preserve the item's grant |
| Claude Code recreating the item or its ACL | **Possibly once** | A replacement can discard third-party grants; this has varied across Claude Code/macOS versions |
| A new session window starting | No | Window resets never touch the keychain |
| Idle, sleep/wake, lock/unlock | No | None of these are keychain reads; a locked keychain defers the read, it does not prompt |
| The endpoint rejecting the saved token | **At most once per renewal** | Tokenmax reads again only after Claude Code writes a new token, not on every tick while it waits |
| After `claude logout` + login | **Possibly once** | If Claude Code recreates the item rather than updating it, the new item carries no grants |

Answer with **Allow** instead and the next keychain read asks again, because
*Allow* covered only the read it was asked for. Tokenmax's memory cache delays
that read until a relaunch, local expiry or a rejected token that Claude Code
has since replaced, which makes the resulting prompts look random even though
the rule is simply one read.

**Why a rejected token no longer means a prompt every five minutes.** A refused
credential used to send Tokenmax straight back to the keychain on the next
tick, which could only return the same refused credential — Claude Code had not
written a new one yet — while costing a dialog each time for anyone who
answered *Allow*. Tokenmax now records when Claude Code last wrote the item and
waits for that timestamp to move before reading again. The item's modification
date is an attribute rather than the secret, so watching it needs no consent.
In the log the wait opens with `waiting for Claude Code to rewrite the item
before reading again` and closes with a read triggered by `Claude Code rewrote
the item after the token was rejected`. If you would rather not wait,
**Refresh** in the popover reads immediately.

**The log records every read, so you can check rather than guess.** Run
`make logs` (or read `~/Library/Application Support/Tokenmax/logs/tokenmax.log`)
and look for `keychain:` lines. Each read logs why it happened (`nothing
cached yet`, `cached token expired`), what came back, how long it took —
and duration is useful evidence: a read served from a grant normally answers
in milliseconds and is logged `silent`, while a slow read is logged `likely
waited on a consent dialog`. Timing cannot prove which system UI appeared, so
the log deliberately says *likely*. Each line also carries when Claude Code
last modified the item, and every launch
logs the binary's `cdhash` — if the hash differs from the previous launch
line, the next prompt is the expected once-per-build one. When reporting a
prompt that seems wrong, these lines are exactly what to include.

**First, check which button you pressed.** The macOS dialog offers *Deny*,
*Allow* and *Always Allow*, and only **Always Allow** writes a grant for the
current item. *Allow* authorises that one read — Tokenmax holds the result in
memory, but must consult the item again after a relaunch, local expiry or
rejected cached token. If the prompt returns a few times a day at seemingly
random moments, this is the first thing to rule out. Answer the next one with
**Always Allow**.

*Deny* is taken at its word. Tokenmax remembers the answer for as long as it
runs and stops asking; the popover shows **Keychain access denied**, and
clicking **Refresh** there is what re-opens the question. A denial never brings
the dialog back on a timer.

A wrong answer is merely annoying rather than unusable: nothing is written to
disk, and a token the endpoint rejects is dropped immediately.

**You build it yourself.** Expect one prompt per build. macOS records the grant
against the app's **code hash**, which changes every time you compile, so each
new binary is a program it has never seen. Nothing is wrong; the previous grant
simply does not apply to the build you just made.

A self-signed certificate does *not* avoid this, despite giving the bundle a
stable designated requirement. Measured on the live item on a cert-signed build:
the decrypt ACL for `Claude Code-credentials` held 89 trusted-application
entries, 87 of them Tokenmax build paths, and the item's partition list held
exactly `apple-tool:` plus a *single* `cdhash:` — one Tokenmax build and
nothing else. Note *single*, and note that it need not be the build you are
running: on the measured machine it named the previously granted binary while a
newer one was installed, which is precisely why that newer one prompted. The
reason is visible in `codesign`: a self-signed certificate carries **no Team
Identifier**, so the only stable-looking thing macOS has to key a grant to is
the per-build hash. A
Developer ID-signed app in the same ACL, which does have a Team Identifier, got
a single entry that has survived its updates.

The certificate is still worth having — it is what keeps macOS *file-access*
grants from being discarded, the failure that strands an unattended run — but it
does not stop the keychain re-prompt. A rebuild-heavy session means a prompt per
rebuild, and it settles as soon as you stop rebuilding.

**You installed a release and it re-prompts.** One prompt per downloaded version
is normal, for the same reason — a new version is a new binary, with a new hash.
If it asks again for a version you have already allowed **with Always Allow**,
that is a bug: check that the bundle identifier has not changed and file an
issue with your macOS version.

**What would actually end it** is signing with an Apple-anchored certificate
(Developer ID, which carries a Team Identifier), so the grant can attach to a
requirement that stays true across versions rather than to a hash that does not.
That needs the paid Apple Developer Program and has not been done yet; see
[docs/RELEASING.md](RELEASING.md#deferred-on-purpose).

**What not to do:** "Allow all applications to access this item" in Keychain
Access does silence it, by handing your Claude OAuth refresh token to every
program on the machine. Do not.

**If you want the dialog gone regardless of buttons and certificates:**
**Settings → Data Source → Status line only** never reads the keychain, so
macOS has nothing to ask about. The trade is real — readings only update while
a Claude Code session is answering, and the opener and automatic runs pause —
but for a machine that mostly wants a meter, it is the honest zero-prompt
option. Install the status-line shim first or the meters will read unknown.

### The app launches but nothing appears

Tokenmax is a menu bar app with no dock icon by default. Look in the menu bar,
not the Dock. If the bar is crowded, macOS may have hidden it — try widening the
bar by quitting another menu bar app, or check with a menu bar manager.

### The icon got wider and pushed my other menu bar items along

You switched the icon to **Rings**. Two rings need about 35pt where two bars
need 20, because an arc has to close a whole circle to read as a meter, while a
bar can share the icon's full width. That is what buys the fourth quota bars
have no room for.

Three ways out, in **Settings → General → Menu bar icon**:

- Go back to **Bars**, which is the narrower shape for two or three quotas.
- Stay on rings but choose **1 ring** — 16pt, *less* than the bars use.
- Switch the countdown off under **Time remaining**, which is usually the wider
  half of the item anyway.

On a MacBook with a notch this is not cosmetic: items that do not fit are hidden
outright rather than wrapped, so the extra width can cost you a different app's
icon entirely.

### The Side Notch does not appear, or appears on the wrong display

It is an Alpha feature and is off by default. Turn on **Settings → General →
Side Notch · Alpha**. In **Side Notch** placement, the collapsed handle belongs
to the display containing the pointer and moves only while collapsed; an open
rail stays put so it cannot jump away during interaction. **Dock Notch** instead
stays flush with the bottom of the display that owns the Dock, with a small gap
from the Dock's live left or right edge. If macOS denies Accessibility inspection, Tokenmax estimates that
edge from the centred Dock's configured tiles and currently running apps. Leave
the rail and detail card for 400ms, then move the pointer to the intended display.
With **Always show Dock Notch** enabled, the compact horizontal rail remains
visible; its detail card still closes 400ms after the pointer leaves both surfaces.
Dock geometry is frozen while the rail is open, so icon magnification and newly
appearing Dock items cannot move the hover target during an inspection.

Tokenmax deliberately hides the panel while the Mac is locked or asleep, and
restores it after the session becomes active. It joins every Space and
full-screen app without becoming the key window. If the setting is on and no
handle appears after unlock, open Settings: the Side Notch section names its
current suppression, and `make logs` records `side notch:` with the same reason.

### The Side Notch ring is empty instead of showing zero

An empty grey track means the value is missing or stale. Zero would claim the
limit is exhausted, which Tokenmax cannot infer from a failed refresh. Open the
menu-bar popover for the provider's freshness and use **Refresh** there; the
Side Notch fills again only after a current reading lands.

### The Tokenmax menu bar item disappeared

**Show the menu bar item** was switched off while Side Notch was enabled. This
is a supported Side-Notch-only setup, not macOS hiding a crowded status item.
Right-click the collapsed handle or open rail and choose **Show Menu Bar Item**.

Tokenmax will not persist a state with both the menu bar item and Side Notch
hidden: switching Side Notch off restores the item first, and a hand-edited
settings file asking for neither is normalized on launch. If neither surface is
visible despite that, relaunch Tokenmax; the menu item is the safe fallback.

### The icon is suddenly coloured and no longer matches my other menu bar icons

Normally the icon is a *template image*: it carries only a shape, and macOS
paints it in whatever colour the menu bar is currently using, exactly as it does
for its own icons. Two settings give that up, both under **Settings → General →
Colour**:

- **Escalating** with a **Base** colour set. A base colour is always on, so the
  icon is never a template. Set **Base** back to **Neutral** — the first swatch,
  the crossed-out circle — and the icon goes back to matching until a level is
  actually reached.
- **Escalating** with a level currently reached. This one is working as
  intended: colour appears because a window is low, and it goes away when the
  window resets.

**Monochrome** switches the whole thing off and restores the original icon.

Note that the "good time to spend" highlight has always had this effect too, for
the same reason — a colour cannot survive being flattened into a template. That
is why the un-lit meters turn grey rather than staying black or white while any
one of them is coloured: menu bar contrast follows your wallpaper, so there is
no correct neutral available, and grey is the one value legible against both
ends.

### A level I set never seems to fire

Three things to check, in order:

1. **Is the reading stale?** Stale meters are never coloured. Unconfirmed data
   dressed up as a measurement is worse than an obviously absent one, so a
   window whose data could not be refreshed shows its muted stub instead.
2. **Is a more severe level winning?** Only the most severe level reached is
   drawn. A level at 50% is invisible whenever a level at 25% also applies.
3. **Is the window also a burn opportunity?** A level triggered by *reminder
   fired* yields to the "good time to spend" highlight, by design — being
   announced says nothing about how much is left. If you want that window
   coloured regardless, give the level a percentage trigger instead;
   percentage-triggered levels outrank the highlight.

Also worth knowing: with a ladder configured, the fixed orange that used to mark
a fired reminder steps aside. If you want that signal back, add a level with the
**reminder fired** trigger and give it the colour you want.

### The rings are hard to read at a glance

Two things are worth knowing before giving up on them. The outer arc is drawn
dimmer on purpose — that is what makes the pair read as one nested object rather
than two circles, and it goes to full strength as soon as that arc is lit or
alerting. And a percentage is genuinely harder to judge from an arc than from a
bar; rings win on *how many* numbers fit and on showing that a session sits
inside a week, not on precision. If what you do with the icon is compare two
numbers closely, bars are the better instrument and switching back is one click.

---

## Quota and meters

### The meters are empty, or say "unknown"

Work through these in order:

1. **Is Claude Code logged in?** Run `claude auth status`. Tokenmax reads the
   token that login stores; without it there is nothing to read.
2. **Was the keychain prompt declined?** The popover says **Keychain access
   denied** if so. Tokenmax takes a *Deny* at its word and stops asking — click
   **Refresh** in the popover to be asked again. Open **Keychain Access** and
   check Tokenmax under the item's Access Control if it still fails.
3. **Is the data source set to Status line only, without the shim?** In that
   mode the only source is the file the shim writes; if the shim is not
   installed — or no Claude Code session has answered since — there is nothing
   to show, and unknown is the honest reading. Install the shim from
   **Settings → Data Source**, or switch back to the keychain source.
4. **Run `make doctor`.** It tells you whether the keychain item still has the
   shape Tokenmax expects and whether the endpoint answers.
5. **Check the log** for `usage:` lines. `usage: SCHEMA DRIFT` means the endpoint
   changed shape and Tokenmax needs updating — see [When upstream
   changes](#when-upstream-changes).

### Quota is stale, or "last known"

Tokenmax carries the last good reading forward rather than showing nothing, and
labels it. Causes, in order of likelihood:

- **Rate limiting.** The client floors network calls at one per 180 seconds; the
  UI ticks more often than that and those ticks are served from cache. This is
  normal and resolves itself.
- **Tokenmax's saved credential was rejected.** An active Claude Code
  conversation can still work on an existing connection, while the keychain
  credential Tokenmax reads remains old. Tokenmax deliberately never refreshes
  it, because that would race Claude Code's own refresh. It keeps checking and
  uses a status-line reading if one is available. Continue working and refresh;
  if Claude Code does not write a replacement, choose **Open Terminal + Copy
  Login** and paste `claude login`.
- **No network.**

Stale data is deliberately conservative: it suppresses pace projection and
automatic runs, but it never cancels a scheduled reminder.

### The numbers disagree with Claude Code's own display

Two sources with different freshness. The usage endpoint can be polled any time;
the statusline only updates while a session is actually running. In the default
keychain mode, when both are available, the fresher and higher-confidence
reading wins. In status-line-only mode there is just the one source, exactly as
fresh as the last session response — a bigger gap between sessions is that mode
working as described, not drift.

A gap of a few percent between them is normal. A gap of tens of percent is worth
an issue.

### Claude Code works, but Tokenmax says its saved credential was rejected

This does not mean your active Claude Code conversation has stopped working.
That conversation can retain a live connection, while Tokenmax independently
reads the last access credential Claude Code wrote to the keychain. The two only
converge when Claude Code renews and writes its login state. Tokenmax never
performs that renewal itself: two programs refreshing the same OAuth login can
invalidate each other's credentials.

Keep working and click **Refresh**; Tokenmax also checks automatically and will
use the status-line quota reading while one is available. If the saved
credential remains rejected, choose **Open Terminal + Copy Login** in the
popover, paste the copied `claude login` command, and complete the sign-in.

### There is no Codex section at all

In order:

1. **Is Codex switched on?** **Settings → Data Source** has a *Monitor Codex
   usage* toggle. Off, it hides everything Codex — that is the switch doing its
   job, not a fault.
2. **Is the CLI installed where Tokenmax looks?** It checks
   `/opt/homebrew/bin/codex`, `/usr/local/bin/codex` and `/usr/bin/codex`, then
   your `PATH`. A `codex` installed somewhere else entirely will not be found.
3. **Is it signed in?** Tokenmax asks the App Server for the account and treats
   "no auth mode" as not signed in. Sign in with the CLI as you normally would
   and refresh.

### Codex says "Not reported for this account"

Not a fault, and deliberately not the same as an empty meter. Codex reports
whichever windows your account actually has; where a session window is not
among them, saying so is more honest than drawing a bar at zero, which would
read as "you have nothing left".

An **API-key** login is the other case: it is billed and unmetered, so there is
no window to report at all. Tokenmax labels it as billed and will not start
quota-gated automatic Codex tasks against it, because there is no quota
condition to gate on.

### Codex quota is stale while Claude's is fine

They are read over completely different transports — Claude over HTTPS to the
usage endpoint, Codex by starting a local `codex app-server` and speaking
JSON-RPC to it. One can fail while the other succeeds.

Tokenmax starts a fresh read-only server per refresh and lets it exit rather
than keeping an agent process alive. If those spawns are failing, `make logs`
records it. A Codex CLI mid-upgrade is the usual cause, and it resolves itself.

A CLI update that renames or drops a flag value looks identical from the UI:
the spawned process exits immediately instead of answering, and Tokenmax
reports "Codex did not answer initialize in time" because nothing ever
replies. `make doctor` checks the flags Tokenmax depends on against the
installed CLI's own `--help` output and names the exact line to fix, so run
it first rather than guessing.

---

## Reminders

### A reminder did not arrive

Reminders are suppressed for named reasons, and every skip is logged. Run
`make logs` and look for the decision line. The reasons:

| Log reason | What it means |
|---|---|
| stale data | Could not confirm quota at the moment it would have fired |
| window unavailable | This plan does not report that session or weekly window |
| unknown reset | No reset timestamp to schedule against |
| fire time passed | The moment had already gone when scheduling ran |
| below minimum quota | Less than your configured minimum remained |
| queue empty | You asked to be told only when tasks are queued |
| already fired | This window already notified |
| quiet hours | The fire time landed inside them |

If it says **already fired**, Settings shows the delivery time
("Already notified at 16:09"). Changing any rule that produced it re-arms the
current window.

If the Codex session row says **this plan reports no such window**, Tokenmax did
receive a valid Codex snapshot, but the account exposed only its weekly quota.
The saved session rule is not lost; it becomes active if a later plan reports
the window.

### Reminders arrive late

If the Mac was asleep, macOS delivers on wake rather than at the scheduled
instant. That is OS behaviour and cannot be worked around by an app.

### Notifications never appear at all

Permission is requested when you enable reminders, not at launch. If you dismissed
that prompt, macOS will not ask again — grant it in **System Settings →
Notifications → Tokenmax**.

### The quota reset confetti did not appear

Open **Settings → Notifications** and click **Preview Confetti**. Preview uses the same
full-screen presenter as a real reset, but deliberately ignores the enable switch and quiet hours;
if it appears, presentation is working and the real event was suppressed by one of its guards.

Automatic confetti requires all of the following: **Celebrate new quota** is on, the event is
selected, the reading is fresh, quiet hours are inactive, and two successive readings prove that
the old reset passed and a later successor window became active. A countdown merely reaching zero
is not enough evidence. Search the Tokenmax log for `celebration:`: a `reset confirmed` line means
the overlay was actually requested, while no line means no qualifying transition was observed.

---

## Queued runs

### Every run fails immediately

Almost always the CLI rejecting a flag Tokenmax passes. This is reported
distinctly — the run shows **"Update needed"** rather than "Failed", and the
notification says *"Tokenmax needs updating for this CLI"*.

Run `make doctor`. If a flag has moved, it names which one.

This is the most likely thing to break after a Claude Code update, because
Tokenmax passes about a dozen flags it does not own. It pauses the queue on
purpose: every following task would fail identically.

### A run hung for its whole runtime limit and produced nothing

If the error says **"It produced no output at all before being stopped"**, the
CLI never started work — it blocked before its first byte. The usual cause is
macOS file permissions.

Tasks in **Documents, Desktop, Downloads or iCloud Drive** are protected by TCC.
The CLI Tokenmax spawns inherits Tokenmax's permissions, so a folder Tokenmax
has not been granted causes the CLI to block on a consent dialog — and an
unattended run has nobody to answer it.

What makes this hard to spot: TCC gates reading a file's *contents*, nothing
else. `stat` succeeds, opening the directory succeeds, and listing its names
succeeds — all on a folder the app cannot actually read. Only opening a file
inside it is refused, which is why the folder looks perfectly fine right up
until a run touches something.

**Tokenmax now asks at launch**, not when a task runs. On startup it tries to
read each folder your queued tasks live in, which is what raises the dialog — at
a moment you are present to answer it. The result is logged as `access: ok` or
`access: DENIED` per folder, so `make logs` tells you where you stand.

If you dismissed it, open the task editor: a blocked folder shows *"macOS is
blocking Tokenmax from reading this folder"* with a **Grant Access** button. Or
allow Tokenmax under **System Settings → Privacy & Security → Files and
Folders**.

**This comes back after every local rebuild if you build ad-hoc.** TCC grants are
keyed to the code signature, and ad-hoc signing produces a new one each time, so
the permission does not carry over. A
[self-signed certificate](../README.md#building-a-release) fixes this one, and it
is the reason to bother with the certificate at all. It does *not* fix the
keychain prompt, which macOS keys to the code hash regardless — see
[The keychain prompt comes back every time](#the-keychain-prompt-comes-back-every-time).

### Will it keep asking for folder permission?

No. macOS asks **once per app, per protected area**, and remembers the answer:

| Working directory | Asks? |
|---|---|
| Anywhere under `~/Documents` once granted | No |
| `~/Desktop/…`, `~/Downloads/…` | Once each — separate grants |
| iCloud Drive, Dropbox, external volumes | Once each |
| `~/Projects`, `~/dev`, `/Users/Shared` | Never — not protected |

So no prompt is normally a sign that everything is granted, not that something
was skipped. Confirm with `make logs`, which records `access: ok` per folder at
launch, or:

```
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select service, auth_value from access where client='com.tokenmax.Tokenmax';"
```

`auth_value` of `2` means granted, `0` means denied.

A prompt that comes back **after it was already granted** means the app's
signature changed — for a locally built copy, that is every rebuild unless you
are signing with a certificate.

### A run failed and the queue stopped

Working as configured — *pause after first failure* is on by default. The
reasoning is that the second failure usually has the same cause as the first, and
burning the queue to discover that is expensive.

Read the error, fix the cause, resume from the queue window. Turn the behaviour
off in **Settings → Queue Automation** if you would rather it kept going.

### The result view is blank but the run succeeded

The transcript is reconstructed from the raw stream on demand. If the stream
format changed upstream, the run still completes but there is nothing recognisable
to display.

Check the log for:

```
transcript: N events parsed but none recognised — stream-json schema may have changed
```

That line means Tokenmax needs updating. The raw NDJSON is still intact under
**Raw Log** — nothing is lost, only the readable rendering.

### A run says it could not do something it had permission for

Open **View Result** and look at the *denied tools* section, which is listed
before the steps. That is usually the whole answer: file tools are confined to
the working directory by path scoping, and shell access is a separate opt-in.

A task that needs to touch files outside its working directory needs shell
access, and that is a deliberate decision rather than an oversight.

### Automatic runs never start

Tokenmax names the failing condition in the popover and in **Settings → Queue
Automation**. The common ones:

- the task is not marked **Always allow automatic execution**
- it has **no runtime estimate** (required — the scheduler cannot reason without one)
- its **runtime limit**, not its estimate, does not fit before the safety margin
- the reading is stale
- automation is still in **preview only** mode
- the Claude data source is **Status line only** — a mode that cannot poll
  cannot confirm what a run just spent, so unattended Claude runs pause until
  the source is switched back; running a task by hand still works

Preview mode is the one people forget. It is deliberately sticky.

### A Codex task never starts automatically

Codex automation has a switch of its own — **Settings → Queue automation →
Codex** — kept separate from Claude's so that enabling unattended Claude runs
cannot hand you a second unattended agent by inheritance. It defaults to off,
including through an upgrade, so this is the first thing to check.

Four more causes are specific to Codex:

- **Codex is not monitored.** Settings → General → *Monitor Codex usage*. A
  provider that is switched off has stopped refreshing, and nothing runs against
  a frozen reading.
- **Codex is signed in with an API key.** There is then no plan allowance to
  meter and the run would be billed per token, so Tokenmax refuses and says so.
  `codex login` with a ChatGPT account fixes it.
- **The window is not close enough to resetting.** If your plan reports only a
  weekly window, that is the one being spent, and the run happens in the lead
  time before the *week* resets — not daily.
- **The window's task allowance is used up.** On a weekly-only plan, the default
  *maximum tasks per window* of one means one task a week. Raise it in the Codex
  section.

The status line in Settings names whichever condition is actually failing, and
the Codex section says which window your own plan reports.

### An appointment came and went and nothing ran

A task with a set time still has to satisfy every condition in the list above
except the timing ones — the date answers "when", not "may this run at all". The
two that catch people are the same two as ever: the task must be marked **Always
allow automatic execution**, and it must have a runtime estimate. The editor
warns about both while you are setting the time, and the card says which one is
missing afterwards.

If the card instead says the appointment **expired**, the Mac was almost
certainly asleep at the time. Nothing evaluates while it sleeps, so an
appointment that comes round unobserved is abandoned once it is older than **Run
a missed appointment up to** minutes (Settings → Queue Automation → Timing)
rather than starting hours late against a project that has moved on. Give it a
new time, or raise that grace period if you routinely close the lid.

An appointment that is simply still in the future reports itself as waiting, not
as a problem, and it does not consume the per-window task or runtime budgets —
so a full window is not the reason either.

### A Codex task ignored the cost cap

There is no cost cap for Codex to ignore. Tokenmax enforces a per-run USD
ceiling for Claude because the CLI reports cost; the Codex CLI offers nothing
equivalent, so the task editor states the limit plainly rather than showing a
control that does not work.

For a Codex task the **runtime limit is the only ceiling**, which makes it worth
setting deliberately instead of leaving the default. The execution boundary is
also a sandbox — read-only, or workspace-write — rather than a per-tool
allowlist, so "can it change files" is answered by the sandbox choice alone.

### "Replying to this run is not available"

Runs recorded before 0.1 shipped threaded replies reported a session ID for a
transcript the CLI has since discarded. There is nothing to resume. The sheet
says so rather than offering a reply that would fail.

Also note transcripts are stored per working directory — changing a task's
directory makes its earlier threads unreachable.

---

## The session opener

### It never fires

**Settings → Session Opener → Check eligibility** evaluates every guard against
the current state and spends nothing. It will name the one that is blocking.

The guards most often responsible:

- **the window already has a successor** — you started a session yourself, so the
  opener correctly stayed quiet
- **weekly quota below threshold** — the five-hour and weekly allowances share one
  budget, so an opener is never free
- **the model's own weekly allowance is below threshold** — Sonnet has one, Haiku
  does not
- **not a first-party subscription** — `claude auth status` must report claude.ai
- **an `apiKeyHelper` or API key in `~/.claude/settings.json`**
- **quiet hours**
- **the Claude data source is Status line only** — the opener cannot verify its
  own run without polling, so it waits until the keychain source is restored

### It says "unverified" and stopped permanently

By design. The opener confirms a run worked by observing the reset timestamp
advance past the moment the request ran. If three attempts cannot confirm a new
window, the cycle is recorded unverified and stops.

Chasing an unconfirmable state with more real requests is the one thing this
feature must not do, so it does not. The next cycle starts clean.

---

## When upstream changes

Tokenmax depends on several things it does not control. All of them can change
without notice, and each announces itself differently:

| What changed | How you find out |
|---|---|
| A CLI flag was renamed | Runs report **"Update needed"**; `make doctor` names the flag |
| The `stream-json` schema moved | Result view blank; log says `transcript: … none recognised` |
| The usage endpoint changed shape | Log says `usage: SCHEMA DRIFT`; meters report it |
| The endpoint moved or vanished | `make doctor` reports 404 |
| Claude Code's keychain format changed | `make doctor` reports it; quota display stops |
| The statusline payload changed | `make doctor` reports the missing key |

**Run `make doctor` after every Claude Code update.** It is the cheapest way to
find drift before a queued run does, and it costs no quota.

If something has genuinely moved upstream, please open an issue with the doctor
output — the fix is usually a few lines, and knowing about it early helps
everyone.

---

## Filing a good issue

Include:

- your macOS version
- whether the app was built locally or installed from a release
- the output of `make doctor`
- the relevant lines from `make logs`

The log records its decisions — `opener: extraUsageEnabled`,
`autorun: noSessionWindow` — and those lines are usually the whole answer.

**Scrub anything private first.** The log records queue task text and working
directory paths.
