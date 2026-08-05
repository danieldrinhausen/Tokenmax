# CLAUDE.md

Read [AGENTS.md](AGENTS.md) before changing anything in this repository. It is
the operating manual for agents working here — commands, the one architectural
pattern, the invariants that must not be "fixed", and the traps that have
already bitten.

Two things worth repeating here because they are the easiest to get wrong:

- **Commit and push after every change, without being asked.** `make test` green
  first, one logical change per commit, push to `origin main`. See
  [AGENTS.md → Git](AGENTS.md#git) for the message style, which the existing
  history specifies.
- **`xcodebuild` prints `error:` lines about simulator devices on a successful
  build.** Check the exit code, never a grep for "error".
