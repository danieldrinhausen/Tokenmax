# Why the keychain prompt behaves the way it does now

A decision record for the changes shipped in `6ae9cad` (remember a denial) and
`e505df1` (status-line-only data source). The user-facing story lives in the
README, the handbook and the troubleshooting guide; this file records the
reasoning — what the problem actually was, which fixes were rejected, and why
the shipped shape is the one that survived.

## The problem, precisely

"The keychain prompt appears randomly, several times a day." Three separate
mechanisms produced that one symptom, and they needed separating because each
has a different correct fix:

1. **An *Allow*-only answer plus a later read.** The macOS consent dialog
   offers *Deny*, *Allow* and *Always Allow*, and only the last writes a
   persistent grant. *Allow* authorises one read; Tokenmax caches the
   credentials in memory, but a relaunch, local expiry or rejected token sends
   it back to the item — a new read and therefore a new dialog. Claude Code may
   also replace or rewrite the item's access control while maintaining its
   credentials; that behaviour has varied across versions and can invalidate
   even a recorded third-party grant. The old explanation reduced all of this
   to "token rotation", which the available evidence did not justify.

2. **A *Deny* that was never remembered.** A denial threw
   `ProviderError.accessDenied`, the refresh loop backed off, and the next
   tick asked again — the app arguing with an answer the user had already
   given, indefinitely.

3. **The per-build hash.** macOS keys the grant to the app's CDHash, so every
   rebuild (and every release) is a program it has never seen. Measured on a
   live item: 87 Tokenmax build paths in one decrypt ACL. A self-signed
   certificate does not help because it carries no Team Identifier — the only
   stable thing macOS can key on remains the hash. Only Developer ID fixes
   this, which is money, not code; it stays deferred in RELEASING.md.

Mechanism 3 is unfixable from inside the repo. Mechanisms 1 and 2 are why the
prompt felt broken, and mechanism 1 is why even a perfect fix for 2 could not
make the prompt *stop* for an *Allow* user. Upstream replacement of the item or
its ACL is likewise outside Tokenmax. That is what forced the second
question: should there be a mode with no prompt at all?

## Decision 1 — remember a denial for the launch, nothing longer

**Shipped:** `ClaudeCredentialCache` remembers an explicit denial and replays
it without touching the keychain; the popover shows **Keychain access denied**;
a manual Refresh is the one thing that clears it.

**Why per-launch and not persisted:** a persisted denial is a setting wearing
an error's clothes. The user who denied in a hurry on Tuesday should not find
monitoring silently dead on Friday with nothing in Settings saying why. A
launch is a natural consent boundary — the same one macOS itself uses for many
grants — and restarting the app is a legible way to be asked again.

**Why manual Refresh clears it:** the retry affordance has to be an act the
user performs, not a timer. Any timer, however long, is the old behaviour with
extra steps — the dialog still comes back uninvited. Refresh is already the
"I want a reading now" gesture, so it is the natural place for "ask me again".

**The distinction that carries the whole design:** only an *answered* dialog
may be remembered. `errSecUserCanceled` and `errSecAuthFailed` mean the user
answered; `errSecInteractionNotAllowed` means macOS could not raise the dialog
at all — a locked keychain during a background tick, typically. Caching that
as a denial would switch monitoring off because a screen was locked at the
wrong moment. It gets its own `KeychainError.interactionNotAllowed`, mapped to
a transient failure, retried like any network blip. This is the "stale data
postpones, never cancels" invariant applied to consent.

## Decision 2 — a data-source choice, not a smarter fallback

**Shipped:** Settings → Data Source picks `keychain` (default, unchanged) or
`statuslineOnly`, which reads nothing but the shim's file.

**Rejected: auto-falling back to the statusline after a denial.** Tempting —
no new setting — but it converts an explicit "no" into silently degraded data.
The user who denied would see numbers that update only mid-session, staleness
they never chose, and no moment at which they chose it. Degradation has to be
picked, with the trade-offs in front of the person picking.

**Rejected: suppressing the dialog with `kSecUseAuthenticationUISkip` or
similar.** Reading the item without the possibility of consent is the wrong
direction entirely; the dialog is the trust boundary, not an obstacle.

**Why the mode must never touch the keychain, not just usually:** the mode's
entire value is a promise — "macOS has nothing to ask about". One quiet
credential read anywhere (an auth check, the model-catalog refresh, which uses
the same token) breaks the promise at an unpredictable moment, which is
exactly the complaint this work exists to fix. So the gate is at every
entrance: `fetchUsage`, `checkAuthentication`, `ModelCatalogStore.refresh`.
A promise kept 95% of the time is not a smaller version of the promise.

**Why `ClaudeDataSourceFlag` exists:** `fetchUsage` runs off the main actor
and cannot read `SettingsStore.settings`. The alternatives were capturing the
value at construction (stale until restart — a settings change that does not
take effect is a bug report) or making the provider main-actor-bound (wrong
for a network client). One lock-guarded word, kept current by the store on
every save, is the smallest thing that works.

## Decision 3 — automation pauses under the statusline-only mode

**Shipped:** `statuslineOnlyMonitoring` skip cases in `QueueAutoRunDecision`
and `SessionOpenerDecision`, surfaced in Settings and the log. Manual runs
unaffected.

The statusline only updates while a session is answering, which makes it
structurally incapable of the one thing unattended spending needs: confirming
state *after* an action, when no user is present to generate statusline
traffic. The opener literally verifies its own run by watching the reset
timestamp advance — a source that cannot be polled cannot see that. The house
rule already decides this: on a quota-spending path, ambiguity resolves to
"do not spend".

**Why a named suppression and not a disabled toggle:** a greyed-out control
explains nothing at the moment someone wonders why nothing ran at 3am. A skip
reason with copy shows up in Settings and the log next to every other reason —
`quietHours`, `staleData` — where the user already looks. This is the "name
every suppression" pattern; the alternative (silently gating) is the exact
shape of bug the pattern exists to prevent.

**Why manual runs still work:** the user standing there clicking Run is the
freshness check. The gate exists because nobody is present; when somebody is,
it has nothing to protect.

## Decision 4 — what the docs had to say, and where

The README owns "why does it behave this way" (read and item-lifetime mechanics, the
*Allow* vs *Always Allow* distinction, what the new mode trades); the
troubleshooting guide owns the symptom ("the prompt comes back every time" —
the words a confused user would search); the handbook owns the workflow (a
recipe: shim first, then switch); the architecture doc owns the pattern (the
flag, the gates, the suppression cases); the info page owns the pitch-level
sentence. One correction ran through all of them: a Developer ID certificate
makes *Always Allow* survive Tokenmax updates, but it does nothing for an
*Allow*-only answer or an upstream replacement of Claude's item — the earlier docs implied signing would end the
prompts, which was a confident wrong sentence, and those are worse than gaps.

## What was deliberately not done

- **No persistence of the denial** — see Decision 1.
- **No auto-switch to statusline-only after repeated denials** — a mode change
  is a user decision; inferring it from behaviour hides a setting change
  behind an error path.
- **No keychain polling to pre-detect rotation** — any scheme that reads the
  item more often to prompt less often has the arithmetic backwards.
- **No third data source** (e.g. parsing transcripts) — transcripts carry no
  rate-limit state; a source that guesses is worse than a gap, which the UI
  already renders honestly as unknown.
