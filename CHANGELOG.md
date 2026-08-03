# Changelog

Notable changes. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semver](https://semver.org/).

## [Unreleased]

### Changed

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
