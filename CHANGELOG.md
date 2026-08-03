# Changelog

Notable changes. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semver](https://semver.org/).

## [Unreleased]

### Fixed

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
