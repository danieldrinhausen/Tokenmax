# Security

Tokenmax reads an OAuth token from your login keychain and can run a coding agent
unattended against your own files. Both deserve a clear statement of what it does
and how to report it when something is wrong.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's [private vulnerability reporting](../../security/advisories/new)
(Security → Report a vulnerability), which stays private until a fix exists.

Please include what an attacker could achieve, the steps to reproduce, and your
macOS and Tokenmax versions. This is a small personal project, not a funded one —
expect a first response within about a week, and no bounty. Credit in the release
notes if you would like it.

## What Tokenmax can reach

Being explicit, because the answer is the basis of any threat model:

**Credentials.** It reads the `Claude Code-credentials` keychain item to obtain
an OAuth access token. macOS gates this behind an explicit user grant. The token
is held in memory for the lifetime of a request, is **never written to disk**,
and is **never refreshed** by Tokenmax — refreshing would race Claude Code's own
refresh. It is sent to exactly one place: `api.anthropic.com`.

**Network.** Outbound requests go to `api.anthropic.com`, for quota and the model
catalogue, and — once a day, unless switched off under **Settings → About** — an
unauthenticated `GET` to `api.github.com` for the newest published release, so
the app can tell you a newer version exists. That request carries no credentials
and no identifying information, and nothing is downloaded or installed as a
result of it. There is no telemetry, no analytics, no crash reporting and no
server of any kind. Nothing you type is transmitted anywhere by Tokenmax.

**Local files.** It reads and writes `~/Library/Application Support/Tokenmax/`.
It reads `~/.claude/settings.json`, and writes to it **only** when you explicitly
install the statusline shim — wrapping any status line already configured rather
than replacing it.

**Process execution.** It spawns the `claude` and `codex` CLIs. This is the
sharpest edge in the app, and the constraints on it are structural:

- `--dangerously-skip-permissions` is never passed, under any setting.
- File tools are confined to the task's working directory by `Write(**)`-style
  path scoping. Without that scoping, an allowlisted `Write` would be
  auto-approved for any path on the machine.
- Shell access is a **separate per-task opt-in**, precisely because a shell
  command escapes that confinement and can reach the whole machine.
- Every run carries a CLI-enforced spend cap and a runtime ceiling.
- The session opener runs with **all tools disabled**, in a fresh temporary
  directory, with an allowlisted environment, and refuses to run under an API key.

## Trust boundaries you should understand

**A queued prompt is executable input.** Tokenmax runs prompts you have saved,
with the permissions you granted that task. Do not queue a prompt you have not
read, from a source you do not trust, any more than you would run a shell script
that way.

**Automation runs while you are not watching.** That is its purpose. Grant shell
access per task rather than by habit, and prefer tasks whose worst outcome is
cheap. [The handbook](docs/HANDBOOK.md#turning-on-automation-without-regretting-it)
covers how to enable it deliberately.

**Local logs contain your content.** Run transcripts and `tokenmax.log` hold
prompt text, working directory paths and CLI output. They never leave your Mac —
but scrub them before pasting into a bug report.

**The app is not sandboxed.** It cannot be: it exists to read another
application's keychain item and spawn CLIs in arbitrary directories. Both are
incompatible with the App Sandbox.

## Distribution

Releases are signed but **not notarized** — notarization requires a paid Apple
Developer account. macOS will therefore warn on first launch, and the README
explains the one-time approval.

This means you should satisfy yourself that a download is genuine. Build from
source if you would rather not extend that trust; `make install` needs only
`xcodegen` and Xcode.

## Out of scope

- The security of Claude Code, Codex, or Anthropic's API.
- What an agent does inside a working directory you granted it.
- Quota figures being wrong or unavailable — that is a bug, not a vulnerability,
  and the primary source is an [undocumented
  endpoint](README.md#disclaimer) with no stability promise.
- Anything requiring an attacker to already have code execution as your user,
  since at that point they can read the keychain themselves.

## Supported versions

Latest release only. This is a personal project; there are no backported fixes.
