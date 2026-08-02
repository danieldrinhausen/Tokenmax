# Tokenmax 0.1

A macOS menubar app that shows remaining Claude Code quota, counts down to reset, projects whether
your current pace runs out early or leaves quota on the table, keeps a local prompt queue, and
notifies you before a window resets so leftover quota gets used instead of evaporating.

The menubar shows two meters — session over weekly — and the time left in the session window
("1h 16m"). The bars carry how much is left; the countdown carries how long there is to spend it.
Settings → General switches between bars, countdown, or both, and offers **Start Tokenmax at
login**.

When the session window is inside your reminder lead time and still holds usable quota, the bars
light up: "now is a good moment to spend this". Settings → General → **Highlight** picks the
colour (six presets, or any colour via the system picker), optionally adds a glow, and can switch
the whole signal off so the icon stays plain at all times. The colour is shared with the matching
banner in the popover. Because menu bar contrast follows your *wallpaper* rather than the
light/dark setting, the pane previews the lit icon against both extremes and warns about a colour
that would disappear into one of them.

```
make install && make run
```

Requires Xcode 26+ and `xcodegen` (`brew install xcodegen`). No Apple Developer account —
the app is ad-hoc signed.

## Where the quota data comes from

The Claude Code CLI has **no** `usage` subcommand, and session transcripts carry no rate-limit
state. Tokenmax uses two real sources instead:

| | Source | Status | Pollable |
|---|---|---|---|
| Primary | `GET api.anthropic.com/api/oauth/usage` | Undocumented | Any time |
| Fallback | Claude Code `statusLine` hook | Documented | Only during a session |

The primary reads the OAuth token Claude Code already stores in your login keychain
(`Claude Code-credentials`). **macOS will prompt once for access** — choose *Always Allow*. The
grant is bound to the code signature, so it re-prompts after each rebuild during development.

Tokenmax never writes credentials to disk, never refreshes the token itself (that would race
Claude Code's own refresh), and sends nothing anywhere except Anthropic.

Requests are floored at **one every 180 seconds** inside the client regardless of what the UI asks
for — the endpoint throttles hard without the exact `User-Agent: claude-code/<version>` header, and
this keeps well inside safe limits. The popover still ticks every 60s; those ticks are served from
cache.

The fallback is opt-in from **Settings → Data Source**. It writes a shim script and sets
`statusLine` in `~/.claude/settings.json`, wrapping any status line you already use. Remove the
`statusLine` key to uninstall.

## Files

Everything lives in `~/Library/Application Support/Tokenmax/`:

```
tokenmax.json            task queue
settings.json            preferences
usage-snapshot.json      last good quota reading
notification-state.json  which reminders already fired
session-opener-state.json which reset cycles the opener already acted on
queue-autorun-state.json run history: what ran, when, what it cost, what it said
run-logs/<runID>.log     raw CLI stream for one task run
statusline-latest.json   captured statusline payload (if shim installed)
logs/tokenmax.log        refresh timing and scheduling decisions
```

All writes are atomic (temp file → `replaceItem`), so a crash mid-write cannot corrupt them.

## Projected pace

Under each meter Tokenmax compares your spending against an **even burn** of the window:

```
Session
▓▓▓▓▓▓▓▓▓▓▓▓░░░│░░░░░░░░░░░░
59% left                    Resets in 3h 34m
12% in deficit          Projected empty in 2h 4m
```

The reference point is what a constant rate would have left at this exact moment — 3h 34m of a
5-hour window still to run means 71% "should" still be there. That is the marker on the bar. Ahead
of the line is a **reserve**, behind it is a **deficit**. The countdown divides the quota left by
the average rate since the window opened (`used ÷ elapsed`).

Everything comes from the reset time and the window length, so it is correct on the first reading
and after a relaunch — no history to accumulate. The lengths come from the endpoint's own field
names: `five_hour` and `seven_day`.

The numbers match [CodexBar](https://github.com/steipete/CodexBar) exactly, which is where this
arithmetic was taken from; its `UsagePace.swift` computes the same `used − expected`. Both halves
of the line fall out of that one comparison, so they cannot contradict each other — a deficit is
*exactly* the condition under which the average rate empties the window early, which is why
"Projected empty" only ever appears next to one.

Two things it will not do:

- **Speak in the first 3% of a window.** `used ÷ elapsed` is dividing by something near zero there,
  so a single early prompt reads as a runaway rate. Costs a session its first ~9 minutes and a week
  its first ~5 hours. Same threshold CodexBar uses.
- **Project from stale data.** Carrying the last good snapshot through a failure is worth doing for
  numbers that were actually measured; extrapolating from them is not, so the pace line drops out
  with the rest of the live data.

Switch it off in **Settings → General → Show projected pace**.

## Notifications

Permission is requested only when you enable reminders — never at launch. Session and weekly
windows are configured independently.

A reminder is scheduled at `resetAt − leadTime` with the identifier
`claude-{window}-{ISO8601 resetAt}`. Because the identifier derives from the reset timestamp,
rescheduling is idempotent — repeated refreshes cannot stack duplicates.

Reminders are suppressed when the data is stale, the reset time is unknown, the fire time has
passed, less than the minimum quota remains, the queue is empty (if configured), the window already
fired, or the fire time lands inside quiet hours. Every skip is logged with its reason.

**"Already notified" respects a rule change.** The fired record stores the lead time, minimum
quota and queue requirement that produced it. Editing any of them re-arms the current window
rather than leaving it suppressed under a rule you have replaced — otherwise a reminder sent
under a four-hour lead keeps blocking the window after you change the lead to 45 minutes, and the
app looks broken while behaving exactly as configured. Settings shows the delivery time
("Already notified at 16:09") so the suppression is never a mystery.

**Stale data never cancels a scheduled reminder.** Every launch begins stale and every failed
refresh returns to stale; those mean "cannot currently confirm", not "the user does not want
this". Only decisions made from known data tear down a pending request. Without this, a run of
failed refreshes silently leaves you with no reminder at all.

Banner actions: **Open Queue**, **Start Manual Session** (opens the queue and copies the
top-priority prompt — it does not execute anything), **Snooze 15 Minutes**. With the queue
switched off only **Snooze 15 Minutes** is offered.

> If your Mac is asleep when a reminder is due, macOS delivers it on wake rather than at the
> scheduled instant. That is OS behavior, not something the app can work around.

## Session opener

A Claude window starts on **first use**, not on a schedule. **Settings → Session Opener** will,
once the current window expires, send one tiny non-interactive request so the next window is already
running when you sit down later.

```
claude --print --model haiku --output-format json --tools "" \
       --strict-mcp-config --disable-slash-commands --setting-sources "" \
       --no-session-persistence --permission-mode manual \
       "Reply with the two characters OK and nothing else."
```

It runs in a fresh empty temp directory with an allowlisted environment, so there is no `CLAUDE.md`
to read, no MCP server to start, no hook to fire, and no inherited `ANTHROPIC_API_KEY`.

**Off by default**, because unlike everything else here it deliberately spends quota. It is worth
switching on only if you want a window *already open* at a predictable later time — opening one
early also starts its five-hour clock.

The opener sends only when every one of these holds:

- the window that ended is still without a successor (if you started a session yourself, it stays quiet);
- the configured delay after the reset has passed;
- the latest usage reading is fresh;
- weekly quota is above your threshold — the five-hour and weekly allowances share one budget, so an
  opener is never free;
- extra paid usage is reported *disabled* (not merely unreported);
- `claude auth status` reports a first-party **claude.ai** subscription;
- `~/.claude/settings.json` carries no `apiKeyHelper` and no API key in `env`;
- it is outside quiet hours;
- nothing has already been sent for this reset cycle.

Two of those are invariants rather than settings: **all tools are always disabled**, and the opener
**never runs under an API key**. A switch for either would only offer a way to turn the safety off.

**Staleness postpones the opener; it never cancels it.** The reset time is on disk and the clock is
local, so Tokenmax always knows the window is up — what a stale reading cannot confirm is the two
quota guards, so it waits. Because there is no deadline, the opener fires on the first good reading
instead of being lost. It spends exactly one backoff-bypassing refresh per cycle trying to unstick
itself, then leaves the ordinary cadence to it.

**Verification is the point.** The reset timestamp must be observed to advance past the moment the
request ran; merely having *a* reset time would let a cached pre-opener reading verify a run that
did nothing. The OAuth client floors network calls at 180s, so the check waits for that floor to
lift rather than reading its own cache back. If three attempts cannot confirm a new window, the
cycle is recorded unverified and **permanently** stops — chasing an unconfirmable state with more
real requests is the one thing this feature must not do.

The cycle identity is the expired reset time, bucketed to absorb the endpoint's second-level jitter,
and it is written to disk *before* the process is spawned — so a crash mid-run cannot produce a
second opener. A run that never reached Claude spent nothing and may retry, up to three times,
five minutes apart.

Settings shows the live verdict, the last attempt, **Check eligibility** (evaluates every guard and
spends nothing) and **Send opener now** (behind a confirmation; the safety conditions still apply).
Every decision is logged with an `opener:` prefix.

> Tokenmax has to be running. If the Mac is asleep at the reset it opens shortly after wake, which
> is usually what you want anyway — waking the Mac is the signal you are back.

## Queue

Add (⌘N), edit, duplicate, copy prompt, move to top, run, mark complete, archive, delete.

**Settings → General → Enable task queue** switches the whole feature off: the popover's queue
section and *Open Queue* button, the queue window, the dock badge, the terminal picker, and the
queue actions on reminder banners all disappear, leaving Tokenmax a pure quota meter. Saved tasks
stay on disk and come back untouched when it is switched on again.

Turning it off does **not** silence reminders. A rule set to "only notify when tasks are queued"
would otherwise suppress every reminder forever once there is no way left to queue anything, so
that condition is ignored while the queue is off and the banner drops its task count.

Each card offers two ways to run. **Run with Claude** executes the task headlessly through
`claude -p` and streams the output to a log. **Open in Terminal**, under the ⋯ menu, is the original
manual path: validate the directory, copy the prompt, open your terminal there, and hand over.

**View Result** opens what the run produced: the model's final answer first, then which tools it
denied (the usual reason a run looks like it under-delivered), then a collapsed list of the steps it
took. The answer can be copied, or the whole thing saved as Markdown. The raw newline-delimited JSON
is still one click away under **Raw Log** — the readable view is reconstructed from it on demand
rather than written as a second file, so it works for a run that was interrupted before it could
summarise itself.

### Replying to a run

`claude -p` cannot ask a question and wait for you. When a run needs a decision it says so in its
final message and exits, which without somewhere to answer means starting over with a longer prompt.

The result sheet has a **reply box**. Sending continues the same conversation — `--resume` on the
stored transcript — with the task's own model, permissions, runtime limit and spend limit unchanged.
A reply is an ordinary manual run, so it is refused for the same reasons any manual run is, and it
never counts against the session's automatic task budget. The sheet then shows the whole thread, turn
by turn.

Replying is worth most on a run that happened while you were away: it stopped on an ambiguity at 3am,
and the conversation is still there in the morning.

Two things follow from how the CLI works. Each turn replays the entire conversation as context, so a
long thread costs progressively more — the running total is in the sheet's header. And transcripts
are stored per working directory, so changing a task's directory makes its earlier threads
unreachable. Runs recorded before 0.1 shipped this cannot be continued at all; they reported a
session ID for a transcript the CLI discarded, and the sheet says so rather than offering a reply
that would fail.

## Queue automation

**Settings → Queue Automation** lets Tokenmax spend quota that would otherwise expire by running a
queued task on its own. Off by default, and in **preview only** mode even once switched on, so the
decision logic can be watched for days before it is trusted with real quota and real file changes.

A task runs automatically only when *all* of this holds: the task is marked **Always allow automatic
execution**, its working directory exists, it has a runtime estimate, the usage reading is fresh, the
session and weekly quotas are both above their thresholds, the session is inside the lead window, no
other run is in flight, the per-session task and runtime budgets have room, and the task's **runtime
limit** — not its estimate — fits before the safety margin. Anything else, and the popover and
Settings say which condition failed.

Each task carries its own limits: model, runtime ceiling, spend ceiling (enforced by the CLI itself
via `--max-budget-usd`), and two capability toggles. File tools are confined to the working directory
with `Write(**)`-style path scoping — without it, an allowlisted `Write` is auto-approved for *any*
path on the machine. Shell access is a separate opt-in precisely because it removes that confinement.
`--dangerously-skip-permissions` is never used.

One task per session window by default, stop on the first failure, and never start a second task
until a usage reading newer than the first one lands.

## Not in 0.1

Sequential multi-task execution · per-task MCP config · git-state guards · Codex adapter ·
multiple accounts.

## Development

```
make build     # compile
make test      # 284 tests
make install   # build, ad-hoc sign, install to /Applications
make logs      # tail the log
make clean
```
