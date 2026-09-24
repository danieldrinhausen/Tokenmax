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
  │  QuotaResetCelebrationDecision │◄─│ QuotaResetCelebrationCoordinator │
  │  SideNotchDecision       │◄─────│  SideNotchCoordinator       │
  └──────────────────────────┘      └─────────────────────────────┘
   enum / struct                     @MainActor
   decides *what* from data in       owns the clock, processes, files
   no I/O, no clock, no state        no rules of its own
```

The decision types take everything they need as parameters and return a verdict.
They never read a file, spawn a process, or call `Date()`. That is what makes
every rule in this app unit-testable without a running app, and it is the single
property most worth preserving.

`MenuBarEscalationDecision` is the same split without a coordinator: the
renderer calls it directly, because the side effect here is one drawing rather
than a process or a timer. It earns its own type anyway. What it holds is a
*precedence* — which of several simultaneous signals a meter should be painted
in — and precedence is the kind of rule that is invisible in a rendered image
and obvious in a test.

`SideNotchDecision` reduces pointer events into `peek`, `rail`, or a selected
provider detail state and names every reason the surface may be suppressed.
`SideNotchLayoutDecision` turns the right-edge placement into panel rectangles
from supplied screen geometry. The coordinator therefore does not acquire the
untested visibility rule.

`TokenmaxApplicationObjects` owns the process-wide reference graph used by every
SwiftUI scene and the AppKit Settings window. SwiftUI may reconstruct its `App`
value; tying coordinators to that value creates parallel stores that agree on
disk but cannot deliver live settings changes to one another.
`SideNotchCoordinator` owns the 400ms close timer, display selection, workspace
notifications and two non-activating `NSPanel`s. Two panels rather than one
large transparent window are load-bearing: a transparent bridge would still
intercept clicks intended for the app underneath. `SideNotchPresentation`
separately resolves menu-bar ring slots into provider-grouped rings without
reading settings or quota on its own. It also carries the selected provider's
plan, freshness, projections, reminder decisions, banked reset credit and
Claude's one-time cloud credit into the detail card. Projection copy, reset-credit
expiry and the cloud-credit line use the same pure
`UsageWindowPresentation` functions as the popover, so the two surfaces cannot
describe one snapshot differently.

`SettingsWindowController` owns one ordinary AppKit settings window whose
content is the shared SwiftUI settings view. Every surface posts the same app
level request, which the controller handles after a contextual menu dismisses;
it then moves the window to the active Space, orders it forward and makes it
key. This deliberately avoids SwiftUI's `showSettingsWindow:` action, which can
report success while leaving an accessory app's Settings window behind another
app. Preferences therefore do not depend on `MenuBarLabel` existing or on the
view appearing for the first time, both essential once the status item can be
hidden.

`MenuBarItemDecision` is the reachability rule for the optional status item. A
request to hide it is accepted only while Side Notch is enabled, and the same
normalization runs while decoding settings. Side Notch's context menu, including
its direct Settings link, is the recovery path. Because the status item may now be absent at launch,
`TokenmaxApp` starts usage, notification, opener, automation and update
coordinators independently of `MenuBarLabel.onAppear`; the label owns only the
AppKit context monitor that cannot exist before its status item does. The
`MenuBarExtra` insertion binding is intentionally one-way: SwiftUI reports its
old scene state while removing the item, but only Settings and Side Notch carry
user intent and may change the persisted visibility preference.

There are four `MenuBarExtra` scenes — the combined item's slot and three
provider slots — because a scene cannot come and go from `body`; `isInserted`
is the only way an item appears or disappears.
`MenuBarItemDecision.items` decides which items exist, left to right: none
while the item is hidden, one per enabled provider under **One icon per
provider** with two or more providers on — in `menuBarProviderOrder`, less
`menuBarHiddenProviders`, and never fewer than one — and otherwise the combined
item. `MenuBarItemDecision.item(inSlot:of:)` then hands those to the slots.
Slots, not one scene per provider, because the order is a setting and nothing
can move a status item: macOS places it and keys its remembered position on
the scene's index, so a slot keeps its item and changes which provider it
draws. Provider slots fill from the right, since macOS inserts a new item to
the left of the existing ones — that assumption is the one to check if a
macOS release starts placing new items elsewhere. The last visible provider
icon refuses to hide with `MenuBarItemSuppressionReason.lastProviderItem`. Every scene's binding goes through the same one-way
reconciliation, so a provider item being torn down never rewrites the user's
choice. `MenuBarItemDecision.layout(for:style:)` gives a provider's item its
own pair — session over week, or Cursor's API over Auto — rather than filtering the cross-provider slot layout,
which could leave it with one bar or none; its countdown and highlight follow
that provider alone. The countdown is `menuBarProviderCountdown` — a window
kind, session or week, resolved per provider by
`MenuBarItemDecision.countdownSource(for:countdown:)` — because the combined
item's `menuBarCountdownSource` names one provider and cannot serve two items.
Settings hides the slot editor and swaps the countdown picker while separate
items are showing; the stored slot layout is never rewritten. The renderer's `ProviderMarker` draws the identifying
glyph in the neutral colour and shifts the meters right, so the combined item,
which has no marker, is pixel-identical to before. Only the first inserted
item answers `.tokenmaxOpenQueue`, since every label receives it. The context
menu already matches any `NSStatusBarButton`, so it needs no per-item wiring.

`NotificationScheduler` evaluates one provider/window rule at a time; a valid
snapshot that omits that window is the named `.windowUnavailable` suppression,
not missing or stale data. A session rule also receives the same provider's
weekly remaining and refuses with `.notEnoughWeeklyQuotaLeft` below the rule's
minimum; `BurnOpportunity` applies the identical check so the highlight and the
reminder cannot disagree about whether a session is worth spending. Delivered requests carry both provider and window in
their metadata. `ReminderRuleSourceResolver` is the pure compatibility boundary
that recovers those values from older identifiers, so the coordinator records
the fingerprint of the exact Codex or Claude rule that fired rather than a
provider-agnostic approximation.

`ClaudeSignIn` holds the rules behind **Sign In with Claude** — the pinned
`auth login --claudeai` arguments, the allowlisted environment, how an exit
status becomes an outcome, and how long to wait before the post-login refresh.
`ClaudeSignInCoordinator`, owned by `ProviderUsageCoordinator` so the login
outlives the popover that started it, spawns the CLI and holds the timer. The
login is Claude Code's, performed and stored by Claude Code: Tokenmax never
sees the token it produces, so the "never refresh the token" invariant is
untouched. The refresh waits for `nextNetworkRefreshAllowedAt`, because the
rejected request started the client's floor and a replay inside it would not
clear `isAwaitingTokenRenewal`.

`ClaudeTokenRenewal` decides when to ask Claude Code to renew a login the usage
endpoint has rejected, and `ClaudeTokenRenewalCoordinator` — owned beside the
sign-in — does it. Claude Code only rotates its token when it runs, so a Mac
where it sat idle past the expiry used to stay on "needs renewal" until the user
signed in again, with a perfectly good refresh token unused. The coordinator
starts `claude` in a pseudo-terminal (`ClaudeRenewalSession`, spawned through
`SpawnedProcess` so the group can be stopped), in an empty folder Tokenmax owns,
with tools, MCP servers and settings files off, types `/status`, and watches the
keychain item's modification date — an attribute read that raises no dialog.
When the date moves it stops the CLI and refreshes after the request floor;
`ClaudeCredentialCache`'s rotation gate opens by itself because the item was
written. The keystrokes are a closed enum, so no code path can type a prompt:
nothing reaches a model and no quota is spent. Automatic runs wait 15 minutes
between attempts and stop after two that left the item unchanged
(`.noEffect`); Refresh skips both waits. Tokenmax still never calls the token
endpoint — Claude Code performs the renewal with its own refresh token, exactly
as it would if the user had opened it.

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
| `SideNotch/` | Pure interaction/presentation decisions and focus-free edge panels |
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
                        ┌────────────────────────────────────────┼───────────┬───────────┐
                        ▼                    ▼                   ▼           ▼           ▼
                  MenuBarIcon           SideNotch          Notifications SessionOpener AutoRun
```

`CountdownClock` is deliberately *not* on that diagram's `UsageRefreshCoordinator`
node. It is a separate observable holding nothing but `now`, and the split is
load-bearing rather than tidiness: `ObservableObject` invalidates per object, so
a property that changes every second rebuilds every view observing whatever
object carries it. While the tick sat beside the readings, `GeneralSettingsView`
— which holds `usage` only to call `previewBurnGlow()` from a button — relaid out
a several-hundred-row `Form` on every tick, and the app ran at a pinned core.

The rule that follows: **observe `CountdownClock` only where a label counts
down.** Anything wanting a reading observes the usage coordinator and pays
nothing for the clock. `ProviderUsageCoordinator` still forwards its children's
`objectWillChange` — a new reading *is* news to the views — but the clock must
never travel through that forward. `CountdownClockTests` pins both halves.

The menu-bar popover and Side Notch register independently as active usage
surfaces. `UsageRefreshCoordinator` keeps a set rather than a Boolean, so
closing one cannot return polling to background cadence while the other remains
open. The OAuth client's own 180-second request floor still applies; foreground
cadence changes UI freshness, not the network safety boundary.

Two usage sources, merged by confidence and freshness in
`ClaudeCodeProvider.merge`. The endpoint can be polled any time; the statusline
only updates while a session runs.

Which sources participate is `ClaudeDataSource`, chosen in Settings and read
off the main actor through `ClaudeDataSourceFlag` (the one word of settings
that has to cross that boundary — `fetchUsage` cannot touch
`SettingsStore.settings`). Under `statuslineOnly` the keychain is never read —
by `fetchUsage`, `checkAuthentication` or the model-catalog refresh — because
the mode's entire promise is that Tokenmax never holds the token; a quiet
fallback to a credential read anywhere would break it. The mode also
adds a named suppression to both spend decisions
(`statuslineOnlyMonitoring` in `QueueAutoRunDecision` and
`SessionOpenerDecision`): a source that cannot be polled cannot confirm what
an unattended run just spent, and ambiguity on a spending path resolves to
"do not spend".

The secret itself is read by running `/usr/bin/security find-generic-password
-w`, not `SecItemCopyMatching`. Claude Code writes the item with that tool, so
the item's decrypt ACL and its `apple-tool:` partition entry already trust it
and survive every rewrite; a read from Tokenmax's own process was keyed to a
per-build cdhash that each Claude Code token rotation evicted, which is why it
prompted about twice a day. `ClaudeKeychain.credentials(fromSecurityExit:…)`
maps the tool's exit status and stderr onto the existing errors, as a pure
function so it is tested without the keychain.

That read sits behind `ClaudeCredentialCache`, which besides caching
credentials remembers an explicit *Deny* for the rest of the launch — reachable
only on a machine whose item does not trust the tool, where `security` raises
the dialog itself. "User canceled" maps to `accessDenied` and is replayed
without touching the keychain again, while "User interaction is not allowed"
(a locked keychain during a background tick) and a tool killed after its
60-second deadline stay transient and are retried. A manual Refresh clears the remembered
denial; nothing else does. The distinction is load-bearing: caching the
transient case would switch monitoring off because a screen was locked at the
wrong moment.

The same cache also gates the read that follows a *rejected* token. Dropping
the credential on a 401 is right; going straight back to the keychain is not,
because until Claude Code writes a replacement the item still holds the token
that was just refused. So `invalidate()` records the item's modification date
and `awaitingRotation` is thrown — no read, no dialog — until that date moves.
The probe is an attribute read, which the item's ACL does not gate, so the
cache can watch for the rotation without consent. It fails open: no timestamp
means read as before, because a redundant read costs a dialog while a gate
stuck shut costs the reading itself. `ClaudeCodeProvider` maps the case to the
same `tokenExpired`/`needsReauthentication` pair the original 401 produced, so
the opener keeps its "awaiting renewal" tolerance instead of seeing a generic
failure.

Local expiry follows the same rule: a token past its `expiresAt` is re-read
only when the item has been written since, and otherwise handed over for the
endpoint to judge. Both are one sentence — *go back to the keychain when, and
only when, Claude Code has written to it* — because neither the clock nor a 401
says anything about what the item currently holds, and the modification date is
the only thing that does. Codex is a parallel path through
`CodexAppServerClient` and does not share these sources: one short-lived
read-only `codex app-server` per read, spoken to over JSON-RPC and allowed to
exit, so no agent process lingers and Codex stays responsible for its own
credentials. The same client answers `model/list`, which is how
`CodexModelCatalogStore` populates the editor's model picker — the counterpart of
`ModelCatalogStore` fetching Anthropic's `/v1/models`. Both cache to disk, both
refresh at most daily, and both are a convenience rather than a gate: every
failure path leaves the task editor usable.

Cursor is a third path, and a usage-only one. `CursorProvider` reads Cursor.app's
sign-in out of its SQLite state database (`CursorStateStore`, read-only, closed
at once) and asks `cursor.com/api/usage-summary`, the endpoint behind Cursor's
own dashboard, through `CursorUsageClient`. The client builds the dashboard's
session cookie from that token in memory and floors requests at 120s. As with
Claude, the token is never written and never refreshed; Cursor renews it by
running. Its two windows, `cursor.api` and `cursor.auto` — API first, because
it is the one that runs out — are the one
`billingCycle` kind, so everything that draws a menu-bar source looks its window
up by id first (`UsageSnapshot.window(for:)`). A lookup by kind would draw
one of Cursor's meters twice. The source that used to be `cursor.total`
decodes as `cursor.auto`, because a saved layout decodes as one array and a
single unknown value would reset all of it. `billingCycle` has no `duration`, so no projection is
made, and no reminder rule, reset event or burn opportunity exists for it: those
are all keyed to session and weekly windows, so Cursor falls out of each by
construction rather than by a check.

`TokenmaxProvider.runsTasks` is what keeps Cursor off the spending path. The
queue coordinator iterates `AppSettings.enabledTaskProviders` rather than
`enabledProviders`, and that list can be empty when only Cursor is watched. The
queue's "selected provider" is the on-screen one only if it can run tasks. Three
layers refuse a task that names Cursor or an unknown id, each with the named
`.providerCannotRunTasks`: `QueueAutoRun.decide`, `manualGate`, and the
coordinator's `run`. The last matters most, because its runner choice is
Codex-or-else-Claude. Side Notch gives any enabled provider whose pair is not in
the four-slot ring layout its fixed pair from `MenuBarItemDecision.sources(for:)`,
so a third provider is never silently missing from it.

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

Codex's App Server and Claude's usage endpoint may additionally report banked
rate-limit resets. Tokenmax carries only their available count and nearest
expiry to the read-only surfaces; the provider's own tool, not Tokenmax, redeems
one. An absent field means the source did not report reset credits, never that
the account has none. Claude's one-time cloud credit travels beside them as
`OneTimeCredit` — deliberately not a `UsageWindow`, which would give a balance
that never refills a ring, a pace projection and reminders.

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
- Past the plan allowance the CLI keeps going and bills usage credits. The
  quota thresholds stop a run well short of that line;
  `stopWhenQuotaExhausted` ends one already under way if a window empties
  anyway. `skipWhenExtraUsageEnabled` refuses categorically and is opt-in —
  credits being enabled says nothing about proximity to the line.
- The opener runs with every tool disabled, in a fresh temp directory, with an
  allowlisted environment, and refuses to run under an API key.

**Codex reaches the same guarantees by different means**, and the difference is
deliberate rather than an omission. Its documented boundary is a sandbox, not a
per-tool allowlist, so `CodexSandbox` (`read-only` / `workspace-write`) carries
what the file and shell toggles carry for Claude — and `-a never` means the run
can never stop on an approval prompt nobody is there to answer. It reports no
per-run cost, so there is no `--max-budget-usd` equivalent to enforce; the
runtime ceiling and the sandbox are the whole budget. The API-key refusal is
shared but arrives differently: Claude's is read from `~/.claude/settings.json`
at gate time, while Codex's is a `ProviderError.apiKeyConfigured` the usage
refresh already discovered, kept as a flag rather than re-derived from an error
message that would break the first time its wording changed.

**Which window is being spent** is `QueueAutoRun.burnWindow`. The session window
whenever the provider reports one; failing that, and only for a provider the
coordinator allows it, the weekly window. Codex on a Plus plan reports a single
seven-day limit and no five-hour one, so without the fallback its queue would
have nothing about to expire to spend against and could never run. Claude reports
both and never takes it.

The fallback changes exactly one gate. Applying `minimumSessionRemainingPercent`
to a weekly burn window would judge one allowance against two thresholds and
refuse at whichever is stricter — so the session floor is skipped there, and the
weekly floor, which governs that same window, still holds. Everything that keys
work to "the window" reads the same choice: the run's identity, the safety
deadline, a failure pause, and the before/after figures on the run record. A
pause cleared for a window nothing ran in is worse than no pause at all.

Because a Codex window can be seven days long, `leadTimeMinutes`,
`maximumTasksPerWindow` and `maximumRuntimeMinutes` are read from
`CodexAutoRunOverrides` for Codex rather than from the shared settings — "one
task per window" against a weekly window means one task a week. Nothing else in
`QueueAutoRunSettings` is duplicated.

An **appointment** — `TokenmaxTask.scheduledStart` — is the one thing that
overrides any of the scheduler's decisions, and it overrides exactly one: which
moment is the right one. In `QueueAutoRunDecision.eligibility` it skips the three
gates that exist to fit a task into the window paying for it, and nothing above
them: approval, a working directory and a runtime estimate are still required,
and every quota floor, quiet-hours rule and per-task limit still applies. It is
checked ahead of ordinary queue order, so a higher-priority undated task cannot
take the slot at the moment an appointment comes round.

Two consequences worth knowing before touching it. Its runs are keyed by
`scheduledWindowID` — derived from the appointment rather than from a reset
timestamp, because a dated run may happen when no window is open at all — which
is also why it does not consume the per-session task and runtime allowances.
And because nothing evaluates while the Mac is asleep, a missed appointment
expires (`scheduleExpired`) rather than running late; `notYetScheduled` is its
waiting state and is a suppression the user need not act on.

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
dozen flags; `ClaudeSignIn.arguments` passes `auth login --claudeai`. CLI surfaces churn faster than APIs and carry no deprecation
contract.

- **Failure mode:** every run fails instantly.
- **Detection:** `ClaudeTaskRunner.rejectedInvocation` matches the rejection in
  stderr and classifies the run as `.incompatibleCLI` — reported as
  "Update needed", not "Failed", with a notification that says so. It pauses the
  queue, because every following task would fail identically.
- **Prevention:** `make doctor` checks each flag against `claude --help`.
- **When it fires:** update the argument builder, then the flag list in
  `Tools/doctor.sh`.

The token renewal (`ClaudeTokenRenewal.arguments`) is the one interactive
invocation, and it depends on something no flag check can see: that Claude
Code renews an expired login when it starts and answers `/status`.

- **Failure mode:** the renewal runs but Claude Code never rewrites the keychain
  item, so the popover stays on "needs renewal".
- **Detection:** the log line `renewal: item unchanged`, and after two misses the
  `.noEffect` suppression in the popover ("Claude Code ran but did not renew its
  login"). Sign In with Claude still recovers.

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
- **Extras, coupled to codenames:** the request adds `?cedar_ember=1`, which
  returns the banked-reset block `cedar_ember` (`eligible`, `grants[].resets_left`,
  `grants[].ends_at`). The one-time cloud credit is read from `iguana_necktie`
  (`limit_dollars`, `remaining_dollars`, `resets_at` as the expiry) with
  `cinder_cove` (percentage only, what Claude Code's own `/usage` reads) as the
  fallback. All three are codenames, so expect them to move. Each decodes on its
  own, so a malformed one drops only itself, never the quota read, and an absent
  one means "not reported". `skip_spend=1`, which Claude Code sends alongside
  `cedar_ember=1`, is left off on purpose: it nulls `extra_usage`, and the
  automation's credit guard reads that field.

Two things here are non-negotiable and enforced inside the client rather than
left to callers: the `User-Agent: claude-code/<version>` header (without it,
requests land in an aggressively rate-limited bucket) and the 180-second floor
between network calls.

### 4. Claude Code's keychain blob

`ClaudeKeychain` decodes another app's private credential format
(`claudeAiOauth` → `accessToken` / `refreshToken` / `expiresAt` /
`subscriptionType`).

The secret is read through `/usr/bin/security`, so the tool's output format
(`-w` printing the stored JSON, exit 44 for a missing item) is part of this
coupling too; `make doctor` reads it the same way.

Every reader goes through one shared `ClaudeCredentialCache`, because each read
spawns a process — and can raise a consent dialog on a machine whose item does
not trust the tool — and there is more than one reader (usage refresh,
model catalog). It caches successes only — never a denial, never a `notFound`,
which would turn "not logged in yet" into a state only a relaunch clears — hands
nothing out past its own `expiresAt`, and is dropped when the endpoint answers
401. In memory for the life of the process; never on disk.

- **Failure mode:** quota display dies; task execution keeps working.
- **Prevention:** `make doctor` verifies the shape.
- **Never:** write credentials to disk, or refresh the token ourselves — that
  would race Claude Code's own refresh. Asking Claude Code to renew
  (`ClaudeTokenRenewal`) is the one sanctioned route.

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

Same flag-drift exposure as the Claude CLI, on a separate release cadence, plus
a second surface the Claude side does not have: Tokenmax speaks JSON-RPC method
names to the App Server, and no `--help` would ever mention those.

- **Failure mode:** a renamed flag or sandbox value fails every Codex run; a
  renamed method fails more quietly, because a notification nobody sends simply
  never arrives.
- **Prevention:** `make doctor` checks the flags, their short forms, the
  `--sandbox` and `--ask-for-approval` values, and every method name — the last
  against the protocol schema `codex app-server generate-json-schema` produces,
  so it tracks the CLI in hand rather than a copy checked in here. Skipped, not
  failed, when Codex is not installed.
- **Already caught one:** `CodexRunObserver` listened for `turn/failed`, which
  the protocol does not have. Failures were reported without their reason until
  the check pointed at it. The reason is inside `turn/completed`, as
  `turn.error`.

### 8. Cursor's dashboard endpoint and state database

Two couplings, both undocumented: `GET cursor.com/api/usage-summary`, which
serves Cursor's web dashboard rather than any promised API, and the key names in
Cursor.app's `state.vscdb` (`cursorAuth/accessToken`,
`cursorAuth/stripeMembershipType`, in table `ItemTable`).

- **Failure mode:** the endpoint's predecessors already changed shape once.
  When Cursor replaced request counts with an included-usage pool,
  `/api/usage` kept answering 200 with a request count of zero. A status check
  alone would call that success.
- **Prevention:** drift is judged by content. A 200 with neither percentage is
  `CursorUsageClientError.schemaDrift`, logged as `cursor: SCHEMA DRIFT` with the
  keys that *are* there. Unlimited plans, team seats and empty bodies are
  exempt, since they legitimately have nothing to meter. `make doctor` counts
  the sign-in row without reading it, and probes the endpoint unauthenticated,
  expecting a 401.
- **Blast radius:** Cursor's section only, and only for someone who switched it
  on. Cursor never feeds a gate that spends anything.

### 9. macOS itself

Annual releases. `MenuBarIconRenderer` does hand-rolled `NSImage` drawing and
SwiftUI layout behaviour shifts between versions.

`MenuBarIconRendererTests`, `MenuBarRingsTests` and `IconSnapshotDump` are the
tripwire — run them each September, and *look at* what the dump writes to
`/tmp/tokenmax-icons/`. The ring metrics in `MenuBarIconRenderer.Ring` are the
part no assertion can defend: they are a budget, not a rule. 16pt of menu bar
height, minus two stroke widths and the ground between the arcs, is what is
left for the hole at the centre, and the hole is what stops a full inner arc
reading as a solid dot. A system change to stroke rendering or menu bar height
spends that budget somewhere else.

Colour is configurable independently of shape. `MenuBarColorScheme` chooses
between the monochrome template and an escalating ladder; `MenuBarEscalation`
holds the rungs and normalizes them on every write (at most three, at most one
reminder rung, thresholds clamped and deduplicated, sorted most severe first) so
that "the level reached" is just the first match. `AppSettings.effectiveEscalation`
is nil while the scheme is monochrome, which keeps that path bit-identical to
the one that shipped before escalation existed — `monochromeIsUnchanged` asserts
exactly that.

A rung persists through a private wire type with every field optional. That is
what lets one rung whose trigger no longer decodes drop on its own while the
rest of the ladder survives, the same tolerance `MenuBarBars` gives a retired
quota source — and it is why the domain type needs no optionals of its own.

`needsRealColor` is the single question that decides templating, replacing a
predicate that had to grow a term for every new colour source. It is reused for
the ring dim, so an escalated outer arc goes to full strength without a second
rule.

The icon has two shapes, and which one is drawn is a setting:
`MenuBarIconStyle` (bars or rings) picks between `MenuBarBars` and
`MenuBarRings`, and `AppSettings.effectiveMenuBarLayout` resolves the pair into
one `MenuBarIconLayout` so no call site can hold a style and a mismatched
layout. Both layout types normalize through the same `normalizedQuotaSlots` —
dedupe, drop disabled providers, pad from the canonical order, truncate — with
a `step` that keeps a ring layout even, since half a ring has no drawing. The
canvas size is therefore style-dependent (`size(style:meterCount:)`), which is
the one thing about the icon that used to be a constant.

Window *activation* is the part that has already moved once. macOS 14 made it
cooperative, which quietly broke `AppDelegate.raise` — see the comment there
before changing the order of those calls.

Two smaller couplings sit in `MenuBarContextMenu`, both to AppKit internals
rather than to public API: that a status item's click arrives on a window whose
view tree contains an `NSStatusBarButton`, and that a local event monitor sees it
before `MenuBarExtra` does. Neither is contractual. If the right-click menu ever
stops appearing, that is where it went.

### 10. The GitHub releases API — lowest risk

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
