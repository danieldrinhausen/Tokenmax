# Quick Capture — Implementation Plan

Folding the Copper/PasteFlow double-shift capture gesture into Tokenmax instead of
shipping it as a separate app.

## Decision

`/Users/daniel/Documents/Git Repositories/PasteFlow/COPPER_PLAN.md` describes a
standalone menu-bar app whose core is a global Left-Shift double-tap that captures the
current text selection into a local queue. Roughly two thirds of that plan already
exists in Tokenmax:

| Copper component | Tokenmax equivalent |
|---|---|
| `CopperItem`, `CopperStatus`, `CopperSource` | `TokenmaxTask`, `TaskStatus` (`Models/TokenmaxTask.swift`) |
| `CopperDocument` schema envelope | `TaskFile` |
| `JSONItemStore` (atomic write, corruption handling) | `JSONStore` + `FileLocations` |
| `CopperViewModel` | `TaskStore` |
| `CopperPanelView`, `ItemRowView`, `EmptyStateView`, `ManualEntryView` | `QueueView`, `TaskCardView`, `TaskEditorView` |
| `StatusBarController` | `MenuBarExtra` in `TokenmaxApp` |
| `PanelController` | `Window(id: TokenmaxWindow.queue)` |
| `DoubleShiftDetector` | **missing** |
| `CGEventSelectionCaptureService` | **missing** |
| `AccessibilityPermissionService` | **missing** |

The infrastructure also already matches on every constraint the Copper brief imposed:
`LSUIElement`, macOS 14 deployment target, Swift 5 language mode, zero external
dependencies, ad-hoc signing, JSON in Application Support, **no sandbox and no hardened
runtime** (`project.yml`) — which is exactly what `CGEvent` posting and global event
monitors require.

So: build only the three missing services, and land captures in Tokenmax's existing
queue.

## Captures land in a new `.inbox` status, not `.ready`

Tokenmax's queue means *"prompts I intend to run against Claude Code"* — each carries a
working directory, priority and execution mode, and `readyCount` feeds the burn-the-quota
notification rules. Arbitrary text grabbed while reading is not that. Dumping selections
straight into `.ready` would pollute the signal that drives notifications.

Captures therefore land in a new `TaskStatus.inbox` and are triaged into real tasks
later. This falls out correctly with no extra work at the consumer sites, because every
one of them already asks for `.ready` specifically:

- `NotificationCoordinator.swift:98` — `queuedCount = taskStore.readyCount`, so
  `onlyWhenTasksQueued` is not satisfied by untriaged captures. Correct: a stray
  paragraph of documentation is not a reason to burn quota.
- `NotificationCoordinator.swift:171` — "Start Manual Session" copies
  `readyTasks.first`, so it can never hand you an untriaged capture.
- `MenuBarPopoverView.swift:209` — the top-3 preview stays a preview of real work.

## Forward-compatibility: harden the enum decoders first

**This must land before or with the `.inbox` case, and it is the one part of this plan
that can destroy data if skipped.**

`TokenmaxTask.init(from:)` decodes status as:

```swift
status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .ready
```

`decodeIfPresent` returns `nil` only when the key is **absent or null**. When the key is
present but holds an unknown raw value — exactly what `"status": "inbox"` looks like to a
build that predates this change — it *throws* `DataCorrupted`. The throw propagates out
of the `[TokenmaxTask]` array decode, `TaskFile` fails, `JSONStore.load` returns `nil`,
and `TaskStore.init` starts from an empty queue. **The entire queue is silently lost.**

The existing `PersistenceCompatibilityTests` do not catch this: every case there covers
*missing* keys, never an unknown enum value.

Fix all three enum decodes in `TokenmaxTask.init(from:)` so an unrecognised value falls
back instead of throwing:

```swift
priority      = (try? container.decodeIfPresent(TaskPriority.self,  forKey: .priority))      ?? .medium
status        = (try? container.decodeIfPresent(TaskStatus.self,    forKey: .status))        ?? .ready
executionMode = (try? container.decodeIfPresent(ExecutionMode.self, forKey: .executionMode)) ?? .manual
```

Do the same for `MenuBarDisplayMode` in `AppSettings.init(from:)`.

This protects every *future* enum addition. It cannot retroactively protect a build
already installed: a Tokenmax binary compiled before this change, reading a file that
contains inbox items, still drops the queue. Accepted — the fix ships in the same
install, and downgrading past it is not a supported path. Worth stating in the README's
data section.

## Model changes

`Models/TokenmaxTask.swift`:

```swift
enum TaskStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case inbox        // new — captured, not yet triaged
    case ready
    case running
    case completed
    case needsAttention
    case archived
}
```

`displayName` for `.inbox` is `"Inbox"`.

Add two fields to `TokenmaxTask`, both optional and decoded leniently like the rest:

```swift
/// Name of the app the selection was captured from, e.g. "Safari". nil for typed tasks.
var capturedFromApp: String?
/// Bundle identifier of that app, kept for the exclusion list and future filtering.
var capturedFromBundleID: String?
```

Nothing else in the model changes. `.inbox` items are ordinary tasks — editing one and
setting its status to `.ready` in `TaskEditorView` is the whole triage flow.

## Settings

Add to `AppSettings` (with lenient decode entries, matching the existing pattern):

```swift
var quickCaptureEnabled: Bool = false
var quickCaptureGesture: QuickCaptureGesture = .doubleLeftShift
var quickCaptureExcludedBundleIDs: [String] = QuickCaptureGesture.defaultExclusions
var quickCaptureShowsHUD: Bool = true
```

```swift
enum QuickCaptureGesture: String, Codable, Sendable, CaseIterable, Identifiable {
    case doubleLeftShift, doubleRightShift

    static let defaultExclusions = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.rider", "com.jetbrains.CLion",
        "com.google.android.studio",
    ]
}
```

**Why the exclusion list is not optional polish:** double-shift is JetBrains' "Search
Everywhere" binding. In any JetBrains IDE the gesture fires against you constantly, and
worse, it fires *while an IDE dialog is opening*, which is the least welcome moment to
post a synthetic Cmd+C. Switching to right-shift does not help — JetBrains listens to
both — so the frontmost-app check is the real mitigation. Checked at trigger time,
before any event is posted.

Default is **off**. Accessibility is never requested at launch, mirroring the existing
notification behaviour ("Permission is requested only when you enable reminders — never
at launch"). Enabling the toggle is what triggers the prompt.

This matters more here than in a standalone app: Tokenmax reads your Claude OAuth token
out of the login keychain. Accessibility trust means the same binary can observe every
keystroke you type. Combining the two is defensible for a personal tool, but it should be
a deliberate opt-in rather than something the app takes at first launch, and the README
should say so plainly.

## New files

xcodegen picks up `Sources/Tokenmax` as a folder reference, so new directories need **no**
`project.yml` edit.

```
Sources/Tokenmax/Capture/
├── AccessibilityPermissionService.swift
├── DoubleShiftDetector.swift
├── SelectionCaptureService.swift
└── QuickCaptureCoordinator.swift
Sources/Tokenmax/Views/
└── CaptureHUD.swift
Tests/TokenmaxTests/
├── DoubleShiftDetectorTests.swift
└── QuickCaptureTests.swift
```

### AccessibilityPermissionService

Straight from the Copper plan, no changes:

- `var isTrusted: Bool` → `AXIsProcessTrusted()`
- `func requestPermission()` → `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
  guarded by a `hasPromptedThisLaunch` flag so a denied grant cannot produce a prompt loop.
- `func openSystemSettings()` →
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

Called only from the settings toggle and from `QuickCaptureCoordinator.start()`.

### DoubleShiftDetector

The Copper plan's state machine is good and should be ported essentially verbatim — its
rules are what make ordinary uppercase typing inert:

- `init(interval: TimeInterval = 0.35, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })`
- Pure entry points the monitors call: `handleFlagsChanged(keyCode:rawFlags:)` and `handleKeyDown()`.
- Left Shift is `keyCode == 56`, right Shift `60`; the configured gesture selects which.
- Up/down derived from the **device-dependent** mask (`0x02` left / `0x04` right) rather
  than `.shift`, so holding the opposite Shift cannot confuse it.
- A *tap* is a clean down→up with no `keyDown` between. Trigger when a second clean tap's
  press occurs within `interval` of the previous tap's release, firing on the second
  release. Any `keyDown` clears the stored tap. A held Shift yields at most one tap.
- `start()` installs both `addGlobalMonitorForEvents` and `addLocalMonitorForEvents` for
  `[.flagsChanged, .keyDown]`; the local monitor returns the event unchanged. `stop()`
  removes every monitor and nils the tokens.

**One deviation from the Copper plan, and it is important.** That plan targeted Swift 5
mode specifically to dodge strict-concurrency churn on AppKit callbacks. Tokenmax sets
`SWIFT_STRICT_CONCURRENCY: complete` in `project.yml` and keeps its builds clean, so the
detector has to satisfy it.

Do **not** hop with `Task { @MainActor in ... }` — the idiom used elsewhere in this
codebase (`NotificationCoordinator.swift:212`) is correct there because those callbacks
are order-independent. This one is not: `Task` enqueue order is not a guaranteed
execution order, and a reordered down/up pair silently corrupts the tap state machine.

`NSEvent` monitor handlers are already delivered on the main thread, so extract the
`Sendable` scalars inside the closure and assert the isolation instead:

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
    let keyCode = event.keyCode
    let rawFlags = event.modifierFlags.rawValue
    let type = event.type
    MainActor.assumeIsolated {
        // dispatch into the pure state machine, synchronously and in order
    }
}
```

This keeps ordering exact and stays warning-clean. The state machine itself is
`@MainActor` and holds no `NSEvent`.

### SelectionCaptureService

Port the Copper plan's `CGEventSelectionCaptureService` as specified — it is careful in
the right places:

- Read frontmost `NSRunningApplication` → snapshot the pasteboard (every item, every
  type, via `data(forType:)`) → record `changeCount` → post Cmd-down / C-down / C-up /
  Cmd-up (`kVK_ANSI_C = 8`, `.maskCommand`, `CGEventSource(stateID: .combinedSessionState)`)
  to the frontmost app's pid via `postToPid` → poll `changeCount` every ~15 ms up to
  ~600 ms → read plain text → restore the snapshot → normalise → return.
- Retry the copy once via `CGEvent.post(tap: .cghidEventTap)` if the change count does
  not move, since `postToPid` is ignored by a meaningful number of apps. Cannot
  double-capture: only one final value is ever read.
- Restoration is attempted on every path, including failures (`defer`).
- **Unchanged `changeCount` means "no selection" and must never fall back to reading the
  existing clipboard.** Keep this rule exactly. It is the plan's best decision and it
  matters more in Tokenmax than it did in Copper — this app already handles credentials,
  and silently vacuuming a password manager's clipboard into a JSON file on disk is the
  precise failure it prevents.

`@MainActor` throughout (it touches `NSPasteboard` and `NSWorkspace`), `async` with
`Task.sleep` for the poll loop.

Tokenmax is never activated by this path.

### QuickCaptureCoordinator

`@MainActor final class`, owned by `TokenmaxApp` alongside the other coordinators and
injected through `SharedEnvironment`. Wires everything and holds the policy:

- `start()` / `stop()`, driven by `settings.quickCaptureEnabled`. Observes the settings
  store so toggling takes effect without a relaunch.
- When enabled but not trusted, poll `isTrusted` on a low-frequency timer (the global
  monitor is inert without it) and start the detector the moment the grant lands — no
  relaunch needed, same as the Copper plan.
- On gesture:
  1. Read the frontmost app. If its bundle ID is in `quickCaptureExcludedBundleIDs`,
     return immediately — before posting any event.
  2. `await selectionCapture.captureSelectedText()`.
  3. Text captured → build a task and add it. Show the HUD.
  4. No selection → post `.tokenmaxOpenQueueNewTask`.
  5. Failure → log it and show the HUD in its failure state. Never an alert; the user is
     in another app and did not ask for a dialog.
- Every outcome writes one line via `Log.shared` — capture succeeded/empty/failed,
  excluded app, permission missing. Consistent with how the refresh and scheduling paths
  are already debuggable after the fact.

Task construction:

- `prompt` = the full normalised selection.
- `title` = first non-empty line, trimmed, truncated to 60 chars with an ellipsis;
  `"Captured text"` if that yields nothing.
- `status = .inbox`, `priority = .medium`, `executionMode = .manual`.
- `capturedFromApp` / `capturedFromBundleID` from the frontmost app.
- `workingDirectory` stays `nil` — triage sets it.

Add `TaskStore.addCapture(_:) -> Bool` rather than reusing `add`, so the duplicate guard
lives next to the data: compare the normalised prompt against existing `.inbox` and
`.ready` tasks and skip on match, returning `false` so the HUD can say "already in
inbox". Normalisation (CRLF→LF, CR→LF, trim, empty→nil) goes on `TokenmaxTask` as a
`static func normalize(_:) -> String?` so capture and manual entry provably share it.

`TaskStore.add` currently assigns `sortIndex = min - 1`, putting new items at the top.
That is right for captures too; no change.

### CaptureHUD

A small borderless `NSPanel`: `.nonactivatingPanel`, `level = .statusBar`,
`canBecomeKey = false`, `ignoresMouseEvents = true`, fades out after ~1.2 s. Positioned
near the menu bar item.

`canBecomeKey = false` is the whole point — the gesture's value is that it does not
interrupt what you were doing. Nothing in this feature may steal focus on the success
path.

States: captured (with the title), duplicate, no selection, failed.

## Existing files to touch

| File | Change |
|---|---|
| `Models/TokenmaxTask.swift` | `.inbox` case; `capturedFrom*` fields; `normalize`; **harden the three enum decodes** |
| `Models/AppSettings.swift` | four `quickCapture*` settings + lenient decode entries; harden `menuBarDisplayMode` |
| `Queue/TaskStore.swift` | `addCapture`, `inboxCount`; leave `readyTasks`/`readyCount` untouched |
| `App/TokenmaxApp.swift` | construct `QuickCaptureCoordinator`, add to `SharedEnvironment`, `.start()` from the menubar label's `onAppear` next to the other coordinators |
| `Views/QueueView.swift` | `.inbox` filter (first in `QueueFilter`, ahead of `.ready`); listen for `.tokenmaxOpenQueueNewTask` → `isCreating = true`; show source app in the empty state hint |
| `Views/TaskCardView.swift` | show `capturedFromApp` when present; a "Move to Ready" action for inbox items |
| `Views/MenuBarPopoverView.swift` | inbox count in `summaryLine` when non-zero |
| `Views/SettingsView.swift` | Quick Capture section in `GeneralSettingsView` — enable toggle, gesture picker, permission status + "Open System Settings", excluded-apps list |
| `Refresh/UsageRefreshCoordinator.swift` | add `.tokenmaxOpenQueueNewTask` to the `Notification.Name` extension (where the others live) |
| `README.md` | Quick Capture section, Accessibility explanation, privacy note, downgrade caveat |

The no-selection path reuses the existing plumbing: `TokenmaxApp.swift:137` already
routes `.tokenmaxOpenQueue` to `openWindow`, and `AppDelegate.windowDidOpen()` already
handles the `.accessory` → `.regular` activation flip. There is no public API to open a
`MenuBarExtra` popover programmatically, so the Queue window is the right target
regardless.

## Build order

1. Harden the enum decoders + `PersistenceCompatibilityTests` cases for unknown values. **Green before anything else.**
2. `.inbox` case, `capturedFrom*` fields, `normalize`, `TaskStore.addCapture` + tests.
3. Queue UI: inbox filter, card treatment, popover count. Verify by hand-editing `tokenmax.json`.
4. `AppSettings` fields + the Settings pane, toggle wired to nothing yet.
5. `AccessibilityPermissionService` + permission status UI.
6. `DoubleShiftDetector` + `DoubleShiftDetectorTests`. **Green before wiring.**
7. `SelectionCaptureService`.
8. `QuickCaptureCoordinator` + `CaptureHUD`; wire the gesture.
9. README, full `make test`, manual pass.

`make build` after each step; `make test` after 1, 2 and 6.

## Tests

Swift Testing (`import Testing`), matching the existing suites — not XCTest, despite what
the Copper plan says.

**`PersistenceCompatibilityTests`** — new cases: a task with `"status": "inbox"` decodes
as `.inbox`; a task with `"status": "notARealStatus"` falls back to `.ready` **and does
not take the rest of the queue with it**; same for an unknown `priority` and
`executionMode`; an inbox task round-trips with its `capturedFrom*` fields.

**`DoubleShiftDetectorTests`** — the Copper list, which is thorough and worth keeping
whole: one tap does not trigger; two valid taps trigger exactly once; slow taps do not
trigger; held Shift does not trigger; `Shift+A` does not trigger; Shift + multiple keys
does not trigger; the configured Shift triggers and the other does not; release-order
handling; `stop()` removes all monitors. All driven through the pure `handle*` entry
points with an injected clock — no real events.

**`QuickCaptureTests`** — title derivation (first line, truncation, whitespace-only,
empty); `normalize` (CRLF/CR/trim/empty→nil); `addCapture` duplicate guard against both
`.inbox` and `.ready`; captures do **not** appear in `readyTasks` or `readyCount`;
exclusion-list matching.

Not unit-testable, and the plan should not pretend otherwise: `SelectionCaptureService`
needs a real app with a real selection. It gets manual verification only.

## Manual verification

Requires a real login session and the Accessibility grant.

1. Fresh install, Quick Capture off → confirm **no** Accessibility prompt at launch.
2. Enable the toggle → prompt appears; grant it; confirm the gesture starts working
   without relaunching.
3. Select text in Safari, double-tap Shift → HUD appears, item lands in Inbox with the
   source app, **Safari stays frontmost and keeps focus**, clipboard content is unchanged.
4. Copy something distinctive first, then capture → confirm the original clipboard is
   restored exactly.
5. Double-tap Shift with no selection → Queue window opens with the new-task sheet.
6. Type uppercase letters, `Shift+A`, and hold Shift → confirm nothing fires.
7. Capture the same text twice → second one reports duplicate, no second row.
8. Triage an inbox item to Ready → confirm it now appears in `readyTasks`, the popover
   top-3, and satisfies `onlyWhenTasksQueued`.
9. With only inbox items queued and `onlyWhenTasksQueued` on → confirm the reminder is
   **suppressed** and the skip reason is logged.
10. Focus a JetBrains IDE (if installed) → confirm the gesture is ignored and logged.
11. Revoke Accessibility while running → confirm the app keeps working and the Settings
    pane reflects the loss.
12. Quit and relaunch → inbox items persist.

## Not in scope

Rich text or images (plain text only) · AX-API capture as an alternative to synthetic
Cmd+C · clipboard history or any continuous monitoring · capture from the menubar menu ·
auto-triage or LLM-assisted titling of captures · per-app capture rules beyond the
exclusion list · syncing.

## Known limitations to document in the README

Inherited from the Copper plan and still true: password fields, some terminals, VMs and
remote desktop clients, and custom text controls will not yield a selection. Apps that
ignore synthetic Cmd+C fail even with the `.cghidEventTap` retry. Promised or dynamic
pasteboard data cannot be perfectly restored. Ad-hoc signing means the Accessibility
grant — like the existing Keychain grant — must be re-approved after each rebuild during
development, which is the main day-to-day friction of developing this feature.
