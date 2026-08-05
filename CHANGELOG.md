# Changelog

Notable changes. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semver](https://semver.org/).

## [Unreleased]

### Added

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
