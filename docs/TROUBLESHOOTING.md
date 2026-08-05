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

Two different situations:

**You built it yourself.** Ad-hoc signing has no certificate, so the bundle has
no stable designated requirement and the keychain ACL falls back to the raw code
hash — which changes on every rebuild. "Always Allow" cannot stick because macOS
considers each build a different program. The fix is a free self-signed
certificate; see [Building a release](../README.md#building-a-release).

**You installed a release and it still re-prompts.** That should not happen.
Check that the bundle identifier has not changed, and file an issue with your
macOS version.

### The app launches but nothing appears

Tokenmax is a menu bar app with no dock icon by default. Look in the menu bar,
not the Dock. If the bar is crowded, macOS may have hidden it — try widening the
bar by quitting another menu bar app, or check with a menu bar manager.

---

## Quota and meters

### The meters are empty, or say "unknown"

Work through these in order:

1. **Is Claude Code logged in?** Run `claude auth status`. Tokenmax reads the
   token that login stores; without it there is nothing to read.
2. **Was the keychain prompt declined?** Open **Keychain Access**, find
   `Claude Code-credentials`, and check Tokenmax under Access Control. Declining
   is remembered as firmly as allowing.
3. **Run `make doctor`.** It tells you whether the keychain item still has the
   shape Tokenmax expects and whether the endpoint answers.
4. **Check the log** for `usage:` lines. `usage: SCHEMA DRIFT` means the endpoint
   changed shape and Tokenmax needs updating — see [When upstream
   changes](#when-upstream-changes).

### Quota is stale, or "last known"

Tokenmax carries the last good reading forward rather than showing nothing, and
labels it. Causes, in order of likelihood:

- **Rate limiting.** The client floors network calls at one per 180 seconds; the
  UI ticks more often than that and those ticks are served from cache. This is
  normal and resolves itself.
- **The token expired.** Claude Code refreshes it; Tokenmax deliberately never
  does, because that would race Claude Code's own refresh. Use Claude Code once
  and the token renews.
- **No network.**

Stale data is deliberately conservative: it suppresses pace projection and
automatic runs, but it never cancels a scheduled reminder.

### The numbers disagree with Claude Code's own display

Two sources with different freshness. The usage endpoint can be polled any time;
the statusline fallback only updates while a session is actually running. When
both are available, the fresher and higher-confidence reading wins.

A gap of a few percent between them is normal. A gap of tens of percent is worth
an issue.

---

## Reminders

### A reminder did not arrive

Reminders are suppressed for named reasons, and every skip is logged. Run
`make logs` and look for the decision line. The reasons:

| Log reason | What it means |
|---|---|
| stale data | Could not confirm quota at the moment it would have fired |
| unknown reset | No reset timestamp to schedule against |
| fire time passed | The moment had already gone when scheduling ran |
| below minimum quota | Less than your configured minimum remained |
| queue empty | You asked to be told only when tasks are queued |
| already fired | This window already notified |
| quiet hours | The fire time landed inside them |

If it says **already fired**, Settings shows the delivery time
("Already notified at 16:09"). Changing any rule that produced it re-arms the
current window.

### Reminders arrive late

If the Mac was asleep, macOS delivers on wake rather than at the scheduled
instant. That is OS behaviour and cannot be worked around by an app.

### Notifications never appear at all

Permission is requested when you enable reminders, not at launch. If you dismissed
that prompt, macOS will not ask again — grant it in **System Settings →
Notifications → Tokenmax**.

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

**This comes back after every local rebuild.** TCC grants are keyed to the code
signature, and ad-hoc signing produces a new one each time, so the permission
does not carry over. It is the same root cause as the keychain prompt, and the
same [self-signed certificate](../README.md#building-a-release) fixes both.

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

Preview mode is the one people forget. It is deliberately sticky.

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
