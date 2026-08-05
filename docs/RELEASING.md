# Releasing Tokenmax

Two parts: a **one-time checklist** for taking the repo public, and the
**repeatable process** for cutting each release afterwards. Delete the one-time
section once it is done.

---

## Where things stand (2026-08-05)

| | |
|---|---|
| GitHub repo | `github.com/danieldrinhausen/Tokenmax` — **still private**; the visibility switch is the one thing left |
| `main` | 18 commits, pushed, in sync with `origin/main`; carries all the release prep |
| Uncommitted | none |
| Stale branch | `queue-cockpit` still exists locally **and on `origin`** — delete both before going public |
| Author email | `152017997+danieldrinhausen@users.noreply.github.com` across all history, verified — no other address appears in any commit; `user.email` is set **repo-locally** |
| Signing | the `Tokenmax Dev` certificate **exists**, and the Makefile detects it automatically — `make sign` resolves to it with no `SIGN_ID=` needed |
| Tests | **449 passing**, 0 failing |
| Info page | `docs/index.html`, ready; GitHub Pages **not enabled yet** — it cannot be until the repo is public |
| Screenshots | `docs/images/`, 10 PNGs, 2.4 MB total |
| Agent notes | `AGENTS.md` and `CLAUDE.md` are deliberately untracked and gitignored |

The pre-rewrite history backup still exists and still verifies as a complete
history (574 KB, tip `d159c15`). It sits in an agent session scratchpad under
`/private/tmp`, so it will not survive a reboot. Once the repo is public and the
rewritten history has been accepted there is nothing left to undo — but until
then, copy it somewhere durable or accept that it disappears the next time this
machine restarts.

---

## One-time: before flipping the repo public

### Code and history

- [ ] Commit the staged work and merge `queue-cockpit` into `main`. The prep
      (LICENSE, CI, README, info page) is all on the working branch, so a public
      `main` without it would be missing every legal and onboarding file.
- [ ] `git push -u origin main`.
- [ ] Re-check no personal address slipped back in — `user.email` is repo-local,
      so a commit made from a different clone would carry the global identity:

      git log --all --format='%ae %ce' | sort -u

- [x] `docs/QUICK_CAPTURE_PLAN.md` does **not** ship — untracked and gitignored
      on 2026-08-05. Beyond describing an unimplemented feature, it details
      Copper/PasteFlow, a separate unpublished app; publishing it would
      pre-announce that one. The file stays on disk.

### Signing (do this before the first DMG)

Ad-hoc signing has no certificate, so the bundle has no stable designated
requirement and the keychain ACL falls back to the raw code hash — which changes
on every build. Users then get re-prompted for Claude credentials on **every
update** and "Always Allow" never sticks.

- [ ] Keychain Access → Certificate Assistant → **Create a Certificate…**
      Name `Tokenmax Dev`, Identity Type **Self Signed Root**, Certificate Type
      **Code Signing**, and **tick "Let me override defaults"**. Three screens
      then matter:
      - *Serial / Validity*: **3650** days. The 365-day default is silent, and
        when it lapses the designated requirement changes and the keychain
        prompts return with nothing to connect them to.
      - *Certificate Information* (third screen): **clear the Email Address
        field**, and Organization / Country while you are there. It pre-fills
        from the Apple ID, and whatever is left lands in the certificate subject
        — which is embedded in every binary signed with it. The first attempt on
        2026-08-03 produced `CN=Tokenmax Dev, C=DE, emailAddress=<the Apple ID
        address>` this way, which is exactly what must not ship.
      - *Subject Alternate Name*: leave every field blank, same reason.
- [ ] Trust it: Keychain Access → double-click `Tokenmax Dev` → **Trust** →
      **Code Signing: Always Trust**. A self-signed root is not valid for signing
      until this is set, and `find-identity -v` will not list it before then.
- [x] Created 2026-08-03. `CN=Tokenmax Dev, C=DE`, no email. SHA-1
      `CCB8514B2912C93EDDF7DDDD30899A046705DDA5`. **Expires 2036-07-31** — every
      release must be signed with this same certificate.
- [ ] Confirm no personal data made it in:

      security find-certificate -c "Tokenmax Dev" -p | openssl x509 -noout -subject -enddate
- [ ] Verify: `security find-identity -v -p codesigning` lists `Tokenmax Dev`. If
      it does not, the Extended Key Usage screen was missing **Code Signing** —
      delete the certificate and rerun the assistant.
- [ ] **Never sign a public build with the `Apple Development` certificate.** Its
      Common Name is the Apple ID email address, and the signing certificate is
      embedded in the signature — `codesign -dvvv` on the shipped app would
      display that address to anyone who downloads it, undoing the history
      rewrite. `Tokenmax Dev` carries no personal data.
- [ ] `export SIGN_ID="Tokenmax Dev"` in your shell profile so every build uses
      it. `SIGN_ID` is `?=` in the Makefile, so a fresh clone still builds ad-hoc
      for anyone else.
- [ ] Rebuild, install, and click **Always Allow** once more — the new identity
      is unknown to the existing ACL. Then rebuild again and confirm no prompt
      appears. *This fix was diagnosed but never applied; treat that second
      rebuild as the actual test.*

### Repo settings

- [ ] Add the repo **description** and **topics**: `macos`, `menubar`,
      `claude-code`, `swiftui`, `quota`.
- [ ] Confirm the README and info-page links resolve once public — both link to
      `github.com/danieldrinhausen/Tokenmax` and `../../releases`.

### Last look before public

- [ ] Re-read the **Disclaimer** in `README.md` and `docs/index.html`. It states
      no affiliation with Anthropic, that the usage endpoint is undocumented and
      may vanish, and that the opener and queue spend real quota on purpose.
      Satisfy yourself this matches how you use it and your account's terms.
- [ ] Skim the log for anything personal before sharing one in an issue — it
      records queue task text and working directory paths.
- [ ] **Settings → General → Change visibility → Public.**

### After going public

**Pages only works on a public repository** under a free account — on a private
one GitHub offers an upgrade instead of the setting, which is why this comes
last rather than with the other repo settings. Nothing needs paying for; it just
has to happen in this order. (The "publish privately" option advertised on that
screen is a GitHub Enterprise feature for access-restricted sites, and is not
what this page wants to be.)

- [ ] **Settings → Pages** → Source `main`, folder `/docs`. Publishes
      `docs/index.html` at `danieldrinhausen.github.io/Tokenmax`.
- [ ] Link that URL from the repo's About panel and from the README.

---

## Every release

1. **Bump the version.** `MARKETING_VERSION` in `project.yml` is the single
   source of truth — the Makefile reads it for the DMG filename.
2. **Update `CHANGELOG.md`** — move `Unreleased` entries under the new version.
3. **Test.** `make test` — must be 343+ passing and green in CI.
4. **Build the image.** `make dmg` (with `SIGN_ID` set, see above). Output lands
   in `dist/Tokenmax-<version>.dmg`; `dist/` is gitignored.
5. **Check the image.** Mount it, confirm the app and the Applications symlink
   are there, and that `codesign --verify` passes:

       hdiutil attach dist/Tokenmax-<version>.dmg
       codesign --verify --verbose=1 "/Volumes/Tokenmax <version>/Tokenmax.app"
       hdiutil detach "/Volumes/Tokenmax <version>"

6. **Tag and publish.**

       git tag -a v<version> -m "Tokenmax <version>"
       git push origin main --tags
       gh release create v<version> dist/Tokenmax-<version>.dmg \
         --title "Tokenmax <version>" --notes-from-tag

7. **Tell people what they will see.** The image is signed but not notarized, so
   the first launch is refused and needs **System Settings → Privacy & Security →
   Open Anyway**. This is in the README and on the info page; repeat it in the
   release notes.

---

## Things that must not regress

**Sign every release with the same certificate.** A different identity changes
the designated requirement, and every user gets re-prompted for keychain access.

**Keep `PRODUCT_BUNDLE_IDENTIFIER` stable.** `com.tokenmax.Tokenmax` is half of
that same requirement.

**`docs/index.html` is the canonical info page.** A copy was published as a
Claude artifact for preview; if the page changes, this file is the one that
matters — Pages serves it.

**CI pins nothing.** `.github/workflows/ci.yml` runs on `macos-latest`. If the
default image ever ships an Xcode too old for Swift Testing, pin the image
(`macos-15`, `macos-26`, …) rather than fiddling with toolchain selection.

**Tests must stay side-effect free.** They run with
`TOKENMAX_SUPPORT_DIR=/tmp/tokenmax-tests` so they never touch a real queue or
settings file. Keep it that way.

---

## Deferred, on purpose

**Notarization.** Removes the Gatekeeper prompt entirely, needs the $99/year
Apple Developer Program. Not worth it for a handful of users; revisit if the
audience grows.

**The session opener is currently blocked by an account setting.** Extra paid
usage is enabled on the account, and "Skip when usage credits may be charged" is
on, so the opener correctly refuses. Not a bug — but expect it as a support
question, since the app reports it as `opener: extraUsageEnabled` in the log and
names the reason in Settings.
