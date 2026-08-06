# Architecture

For contributors, and for whoever maintains this after an upstream change breaks
it — which, given what it depends on, is the likeliest reason anyone opens this
file.

[CONTRIBUTING.md](../CONTRIBUTING.md) covers the conventions a change should
follow. This covers the shape those conventions produce, and where the app is
load-bearing on things it does not own.

---

## The one pattern

Everything follows the same split:

```
        pure decision                  side-effecting coordinator
  ┌──────────────────────────┐      ┌─────────────────────────────┐
  │  SessionOpenerDecision   │◄─────│  SessionOpenerCoordinator   │
  │  NotificationScheduler   │◄─────│  NotificationCoordinator    │
  │  QueueAutoRunDecision    │◄─────│  QueueAutoRunCoordinator    │
  └──────────────────────────┘      └─────────────────────────────┘
   enum / struct                     @MainActor
   decides *what* from data in       owns the clock, processes, files
   no I/O, no clock, no state        no rules of its own
```

The decision types take everything they need as parameters and return a verdict.
They never read a file, spawn a process, or call `Date()`. That is what makes
every rule in this app unit-testable without a running app, and it is the single
property most worth preserving.

**Corollary:** when something decides *not* to act, the reason is a case in an
enum with human-readable copy — never a bare `return`. The user sees it in
Settings, it appears in the log, and it is assertable in a test. A new guard
means a new case.

## Module map

| Directory | Holds |
|---|---|
| `App/` | Lifecycle, menu bar icon rendering, login item |
| `Providers/` | Everything that talks to something outside the app |
| `Refresh/` | Polling cadence, backoff, staleness |
| `Models/` | Value types, settings, quota math |
| `Notifications/` | Reminder scheduling and suppression |
| `Opener/` | Session opener decision and execution |
| `AutoRun/` | Task execution, transcripts, automation |
| `Queue/` | Task storage, list filtering and sorting |
| `Update/` | Version comparison and the daily release check |
| `Persistence/` | Atomic JSON storage, file locations |
| `Views/` | SwiftUI, no business rules |

`Providers/` is the boundary. Everything fragile lives there or is reached
through it — which is deliberate, because it means the [drift
map](#the-drift-map) below has a small footprint.

## Data flow

```
  Claude Code keychain ──┐
                         ├──► ClaudeOAuthUsageClient ──┐
  api.anthropic.com    ──┘                             │
                                                       ├──► ClaudeCodeProvider
  ~/.claude statusLine ──► StatuslineUsageReader ──────┘         │
                                                                 ▼
                                                    UsageRefreshCoordinator
                                                                 │
                        ┌────────────────────────────────────────┼───────────┐
                        ▼                    ▼                   ▼           ▼
                  MenuBarIcon           Notifications       SessionOpener  AutoRun
```

Two usage sources, merged by confidence and freshness in
`ClaudeCodeProvider.merge`. The endpoint can be polled any time; the statusline
only updates while a session runs. Codex is a parallel path through
`CodexAppServerClient` and does not share these sources.

**One rule governs the whole right-hand side:** stale data postpones, it does not
cancel. A failed refresh means "cannot currently confirm", not "the user does not
want this". Reminders stay scheduled, the opener waits rather than skipping its
cycle, and automatic runs decline until a reading lands. Getting this backwards
produces an app that silently stops working after a network blip.

## Persistence

All state is JSON under `~/Library/Application Support/Tokenmax/`, written
atomically (temp file → `replaceItem`) so a crash mid-write cannot corrupt it.

Two invariants worth knowing before touching `Persistence/`:

**Decoders are tolerant.** Every `decodeIfPresent(...) ?? default` is load-bearing
— it is what lets an older file open in a newer build, and (because unknown enum
cases fall back rather than throw) a newer file open in an older build.
`QueueAutoRunState.swift` decodes an unrecognised run status as `.interrupted`
rather than failing. `PersistenceCompatibilityTests` guards this; if you add a
field, add a case there.

**Nothing grows without bound.** Run transcripts are deleted when their run falls
out of the last-40 history; `tokenmax.log` rotates at 1 MB keeping one previous
generation. Both hold user content — prompt text, directory paths, CLI output —
so neither is allowed to accumulate.

## Execution safety

The queue runner and the session opener both spend real money. Their guards are
structural, not configurable:

- `--dangerously-skip-permissions` is never passed, anywhere.
- File tools are confined to the working directory by `Write(**)`-style path
  scoping. Without it an allowlisted `Write` is auto-approved for *any* path.
- Shell access is a separate opt-in because it removes that confinement.
- Each run carries a CLI-enforced spend cap (`--max-budget-usd`) and a runtime
  ceiling enforced by Tokenmax.
- The opener runs with every tool disabled, in a fresh temp directory, with an
  allowlisted environment, and refuses to run under an API key.

`ClaudeTaskRunner.environment` and `ClaudeOpenerRunner.environment` differ on
purpose — a denylist for the runner (real projects need a working `PATH`), an
allowlist for the opener (which needs nothing). The comment there says not to
make them consistent. It means it.

---

## The drift map

Tokenmax has **no third-party dependencies**. Everything that can break is a
coupling to something outside the repo. This is the complete list, ordered by how
likely each is to bite.

### 1. Claude Code CLI flags — highest risk

`ClaudeTaskRunner.buildArguments` and `ClaudeOpenerRunner.arguments` pass about a
dozen flags. CLI surfaces churn faster than APIs and carry no deprecation
contract.

- **Failure mode:** every run fails instantly.
- **Detection:** `ClaudeTaskRunner.rejectedInvocation` matches the rejection in
  stderr and classifies the run as `.incompatibleCLI` — reported as
  "Update needed", not "Failed", with a notification that says so. It pauses the
  queue, because every following task would fail identically.
- **Prevention:** `make doctor` checks each flag against `claude --help`.
- **When it fires:** update the argument builder, then the flag list in
  `Tools/doctor.sh`.

### 2. The `stream-json` event schema — quietest risk

`RunTranscript.parse` keys on `assistant` / `result` events and `text` /
`tool_use` blocks.

- **Failure mode:** runs succeed, the result view is blank. Nothing else reports
  a problem.
- **Detection:** `RunTranscript.parse` logs when it parses well-formed events but
  recognises none of them.
- **Note:** the raw NDJSON is always preserved, so only the rendering is lost.

`RunTranscript` also maps tool names to their headline argument (`Read` →
`file_path`, `Bash` → `command`). New tools render generically; this is cosmetic.

### 3. The OAuth usage endpoint

`ClaudeOAuthUsageClient` calls `api.anthropic.com/api/oauth/usage` — undocumented,
with a date-pinned `anthropic-beta` header.

- **Failure mode:** quota display stops.
- **Detection:** `ClaudeOAuthUsageClient.driftedKeys` distinguishes a *renamed*
  window set from a merely empty response, and throws `.schemaDrift` rather than
  reporting "no data". Both halves of that test matter: all-nil alone is not
  drift, because an account with nothing to report legitimately returns
  `"five_hour": null`.
- **Well-insulated by:** reading `utilization` and `resets_at` off the response
  instead of hardcoding plan limits. New plans need no code change.

Two things here are non-negotiable and enforced inside the client rather than
left to callers: the `User-Agent: claude-code/<version>` header (without it,
requests land in an aggressively rate-limited bucket) and the 180-second floor
between network calls.

### 4. Claude Code's keychain blob

`ClaudeKeychain` decodes another app's private credential format
(`claudeAiOauth` → `accessToken` / `refreshToken` / `expiresAt` /
`subscriptionType`).

- **Failure mode:** quota display dies; task execution keeps working.
- **Prevention:** `make doctor` verifies the shape.
- **Never:** write credentials to disk, or refresh the token — that would race
  Claude Code's own refresh.

### 5. Model identifiers

`QueueAutoRunSettings.modelOptions` hardcodes the alias list; `ModelCatalog`
infers family by substring.

- **Failure mode:** a new family is missing from the picker.
- **Well-insulated by:** the catalog being fetched live from `/v1/models`, and
  the model field being a free-form `String` — an unknown model is typeable, not
  blocked.

### 6. `~/.claude/settings.json` and the statusline payload

`StatuslineShimInstaller` writes into Claude Code's config and parses its
statusline payload keys.

- **Failure mode:** the fallback source goes quiet.
- **Prevention:** `make doctor` validates the settings file and checks the
  payload keys.
- **Care required:** this file belongs to another application. The installer
  wraps an existing status line rather than replacing it, and removing the
  `statusLine` key is a complete uninstall.

### 7. Codex CLI and App Server

Same flag-drift exposure, separate release cadence, no equivalent detection yet.

### 8. macOS itself

Annual releases. `MenuBarIconRenderer` does hand-rolled `NSImage` drawing and
SwiftUI layout behaviour shifts between versions.

`MenuBarIconRendererTests` and `IconSnapshotDump` are the tripwire — run them
each September.

Window *activation* is the part that has already moved once. macOS 14 made it
cooperative, which quietly broke `AppDelegate.raise` — see the comment there
before changing the order of those calls.

Two smaller couplings sit in `MenuBarContextMenu`, both to AppKit internals
rather than to public API: that a status item's click arrives on a window whose
view tree contains an `NSStatusBarButton`, and that a local event monitor sees it
before `MenuBarExtra` does. Neither is contractual. If the right-click menu ever
stops appearing, that is where it went.

### 9. The GitHub releases API — lowest risk

`GitHubReleaseClient` reads `tag_name` and `html_url` from
`/repos/.../releases/latest`.

- **Failure mode:** the update check reports that it could not complete. Nothing
  else in the app depends on it.
- **Detection:** `UpdateCheckError.schemaDrift`, surfaced in Settings → About and
  the log. A check that fails never claims "up to date".
- **Note:** an unauthenticated caller gets 60 requests an hour per IP. At one
  request a day there is no realistic way to reach it.

---

## Maintenance rhythm

**After every Claude Code update:** run `make doctor`, then run one real task
through the queue. That single task exercises the flags, the transcript parser,
the keychain read and the statusline payload — most of the real exposure.

**Each September:** run the icon snapshot tests against the new macOS.

**Ongoing:** nothing. There are no dependencies to bump.

The gap worth naming: nothing in the test suite touches the live CLI or the
network, so drift can only be caught at runtime or by `make doctor` — never by
CI. That is a deliberate trade (tests stay fast, hermetic and free), but it means
`make doctor` is not optional.

---

## Testing

Swift Testing (`@Test`, `#expect`), no network, no side effects. They
run with `TOKENMAX_SUPPORT_DIR=/tmp/tokenmax-tests` so they never touch a real
queue.

The decision types are where the density is, and that is the point of the split:
`SessionOpenerDecision` and `QueueAutoRunDecision` can be exhaustively tested
against every combination of quota, freshness and settings without spawning
anything or waiting for a clock.

Anything on a quota-spending path needs a test that proves it **refuses** in the
unsafe case. Ambiguity resolves to "do not spend".
