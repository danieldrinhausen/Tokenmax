#!/bin/bash
# Checks the surfaces Tokenmax does not own, so upstream drift is found here
# rather than in the middle of a queued run.
#
# Every check names the file that would need editing if it fails. Exit code is
# the number of failures, so CI can gate on it; warnings do not count.
#
# Run with: make doctor

set -uo pipefail

failures=0
warnings=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; failures=$((failures + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; warnings=$((warnings + 1)); }
note() { printf '    %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- 1. The Claude CLI ------------------------------------------------------
# Same search order as ClaudeCLIClient.locate().

section "Claude CLI"

claude_bin=""
for candidate in \
    /opt/homebrew/bin/claude \
    /usr/local/bin/claude \
    /usr/bin/claude \
    "$HOME/.local/bin/claude" \
    "$HOME/.bun/bin/claude"
do
    if [ -x "$candidate" ]; then claude_bin="$candidate"; break; fi
done

if [ -z "$claude_bin" ]; then
    claude_bin="$(command -v claude 2>/dev/null || true)"
    if [ -n "$claude_bin" ]; then
        warn "claude found on PATH at $claude_bin, but not in any path Tokenmax searches"
        note "Tokenmax will report 'The claude CLI could not be found'."
        note "Add the path to Sources/Tokenmax/Providers/ClaudeCLIClient.swift:31"
    fi
fi

if [ -z "$claude_bin" ]; then
    fail "claude CLI not found"
    note "Searched the same paths as ClaudeCLIClient.swift:31-41"
else
    pass "claude at $claude_bin ($("$claude_bin" --version 2>/dev/null | head -1))"
fi

# --- 2. The flags Tokenmax passes ------------------------------------------
# The highest-churn coupling in the app: a renamed flag fails every run.
# Checked against --help rather than by running the CLI, so this costs nothing
# and consumes no quota.

section "CLI flags Tokenmax depends on"

if [ -n "$claude_bin" ]; then
    help_text="$("$claude_bin" --help 2>&1)"

    # Kept in sync with ClaudeTaskRunner.buildArguments (ClaudeTaskRunner.swift:78)
    # and ClaudeOpenerRunner.arguments (ClaudeOpenerRunner.swift:40).
    runner_flags=(
        --print --model --effort --output-format --verbose
        --max-budget-usd --allowedTools --strict-mcp-config --resume
    )
    opener_flags=(
        --tools --disable-slash-commands --setting-sources
        --no-session-persistence --permission-mode
    )

    missing=()
    for flag in "${runner_flags[@]}" "${opener_flags[@]}"; do
        if ! printf '%s' "$help_text" | grep -q -- "$flag"; then
            missing+=("$flag")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        pass "all ${#runner_flags[@]} runner + ${#opener_flags[@]} opener flags still present"
    else
        fail "${#missing[@]} flag(s) missing from --help: ${missing[*]}"
        note "Runs will fail immediately. Fix ClaudeTaskRunner.swift:78 and/or"
        note "ClaudeOpenerRunner.swift:40, then update the lists in this script."
    fi

    # --output-format stream-json is what RunTranscript parses; a change to the
    # accepted values is as breaking as a removed flag.
    if printf '%s' "$help_text" | grep -q "stream-json"; then
        pass "--output-format still advertises stream-json"
    else
        warn "stream-json not mentioned in --help"
        note "RunTranscript.swift parses this stream; verify before shipping."
    fi
else
    warn "skipped — no CLI to ask"
fi

# --- 3. Claude Code credentials --------------------------------------------
# Tokenmax reads another app's keychain item and decodes its private shape.

section "Claude credentials (keychain)"

if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    blob="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
    if [ -z "$blob" ]; then
        warn "keychain item exists but could not be read without prompting"
        note "Expected when Tokenmax is ad-hoc signed; see Makefile:12"
    elif printf '%s' "$blob" | grep -q "claudeAiOauth"; then
        pass "credential item present and still shaped as claudeAiOauth"
        for key in accessToken refreshToken subscriptionType; do
            if ! printf '%s' "$blob" | grep -q "$key"; then
                fail "claudeAiOauth.$key missing — ClaudeKeychain.swift:80 will throw .malformed"
            fi
        done
    else
        fail "credential item no longer contains claudeAiOauth"
        note "Quota display will break. Fix ClaudeKeychain.swift:80"
    fi
else
    warn "no 'Claude Code-credentials' keychain item — log in with the CLI first"
fi

# --- 4. The usage endpoint --------------------------------------------------
# Undocumented and unversioned apart from the beta header. Reachability only:
# a real call needs a token, which this script deliberately does not handle.
#
# The User-Agent matters: ClaudeOAuthUsageClient.swift:105 documents that
# requests without it land in an aggressively rate-limited bucket and get
# persistent 429s. Probing without it just measures that bucket.

section "Usage endpoint"

probe_ua="claude-code/$("$claude_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H "User-Agent: $probe_ua" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null || echo 000)"

case "$status" in
    401|403) pass "reachable, rejects the unauthenticated probe ($status) as expected" ;;
    000)     fail "unreachable (network down, or the host moved)" ;;
    404)     fail "404 — the endpoint moved. Fix ClaudeOAuthUsageClient.swift:112" ;;
    429)     warn "rate limited (429) — try again later" ;;
    200)     warn "200 without a token, which is unexpected; check the response shape" ;;
    *)       warn "unexpected status $status" ;;
esac

# --- 5. Model catalog endpoint ---------------------------------------------

section "Model catalog endpoint"

status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H "User-Agent: $probe_ua" \
    'https://api.anthropic.com/v1/models?limit=100' 2>/dev/null || echo 000)"

case "$status" in
    401|403) pass "reachable, rejects the unauthenticated probe ($status) as expected" ;;
    000)     fail "unreachable" ;;
    404)     fail "404 — fix ClaudeModelCatalogClient.swift:27" ;;
    *)       warn "unexpected status $status" ;;
esac

# --- 6. Statusline shim -----------------------------------------------------
# Writes into a file another app owns, and parses that app's payload keys.

section "Statusline shim"

settings="$HOME/.claude/settings.json"
if [ ! -f "$settings" ]; then
    warn "no ~/.claude/settings.json — shim not installed (optional)"
elif ! /usr/bin/jq -e . "$settings" >/dev/null 2>&1; then
    fail "~/.claude/settings.json is not valid JSON"
    note "Claude Code will ignore it entirely. See StatuslineShimInstaller.swift"
else
    pass "~/.claude/settings.json is valid JSON"
    if /usr/bin/jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
        shim="$(/usr/bin/jq -r '.statusLine.command // empty' "$settings")"
        if [ -n "$shim" ] && [ ! -x "${shim%% *}" ]; then
            fail "statusLine command is not executable: $shim"
        else
            pass "statusLine configured"
        fi
    fi

    latest="$HOME/Library/Application Support/Tokenmax/statusline-latest.json"
    if [ -f "$latest" ]; then
        # The keys the shim reads out of Claude Code's payload.
        for key in '.model.display_name' '.rate_limits.five_hour.used_percentage'; do
            if /usr/bin/jq -e "$key" "$latest" >/dev/null 2>&1; then
                pass "payload still carries $key"
            else
                fail "payload no longer carries $key"
                note "Claude Code changed its statusline schema."
                note "Fix StatuslineShimInstaller.swift:36"
            fi
        done
    fi
fi

# --- 7. The Codex CLI -------------------------------------------------------
# Same exposure as the Claude flags above, on a separate release cadence.
# Tokenmax speaks two things to Codex: command-line flags, and JSON-RPC method
# names over the App Server. A rename in either fails every Codex run, and the
# method names are the half no --help would ever have caught.

section "Codex CLI"

# Same search order as CodexCLIClient.locate().
codex_bin=""
for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex /usr/bin/codex; do
    if [ -x "$candidate" ]; then codex_bin="$candidate"; break; fi
done

if [ -z "$codex_bin" ]; then
    codex_bin="$(command -v codex 2>/dev/null || true)"
fi

if [ -z "$codex_bin" ]; then
    # Not a failure: Codex is optional, and someone who only uses Claude should
    # not see a red cross for a CLI they deliberately do not have.
    warn "codex CLI not found — skipping Codex checks"
    note "Searched the same paths as CodexCLIClient.swift:8-18"
else
    pass "codex at $codex_bin ($("$codex_bin" --version 2>/dev/null | head -1))"

    codex_help="$("$codex_bin" --help 2>&1)"

    # Kept in sync with CodexTaskRunner.arguments (CodexTaskRunner.swift:53)
    # and CodexAppServerClient.withSession (CodexAppServerClient.swift:80).
    codex_flags=(--sandbox --ask-for-approval --config)
    missing=()
    for flag in "${codex_flags[@]}"; do
        if ! printf '%s' "$codex_help" | grep -q -- "$flag"; then
            missing+=("$flag")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        pass "all ${#codex_flags[@]} codex flags still present"
    else
        fail "${#missing[@]} codex flag(s) missing from --help: ${missing[*]}"
        note "Codex runs and usage reads will fail. Fix CodexTaskRunner.swift:53"
        note "and CodexAppServerClient.swift, then update the list in this script."
    fi

    # Tokenmax passes the short forms, so a long-only rename would still break it.
    for pair in "-s:--sandbox" "-a:--ask-for-approval" "-c:--config"; do
        short="${pair%%:*}"; long="${pair##*:}"
        if printf '%s' "$codex_help" | grep -q -- "$short, $long"; then
            pass "$short is still short for $long"
        else
            fail "$short no longer pairs with $long"
            note "CodexTaskRunner.swift:53 passes the short form."
        fi
    done

    # The two sandbox values CodexSandbox can produce. A removed value is as
    # breaking as a removed flag, and fails only once a run is already going.
    for mode in read-only workspace-write; do
        if printf '%s' "$codex_help" | grep -q -- "$mode"; then
            pass "--sandbox still accepts $mode"
        else
            fail "--sandbox no longer advertises $mode"
            note "Fix CodexSandbox in CodexExecutionPolicy.swift:3"
        fi
    done

    # CodexTaskRunner hardcodes `never`; the usage read uses `untrusted`.
    for policy in never untrusted; do
        if printf '%s' "$codex_help" | grep -q -- "$policy"; then
            pass "--ask-for-approval still accepts $policy"
        else
            fail "--ask-for-approval no longer advertises $policy"
            note "Fix CodexTaskRunner.swift:53 / CodexAppServerClient.swift:55"
        fi
    done

    if printf '%s' "$codex_help" | grep -q "app-server"; then
        pass "app-server subcommand still present"
    else
        fail "app-server subcommand is gone"
        note "Both the usage read and every Codex run go through it."
    fi

    # The JSON-RPC method names, which no --help advertises. Taken from the
    # protocol schema the CLI generates, so this tracks the CLI in hand rather
    # than a copy of the protocol checked in here.
    schema_dir="$(mktemp -d)"
    if "$codex_bin" app-server generate-json-schema --out "$schema_dir" >/dev/null 2>&1; then
        # Grepped from the files rather than through a pipe. The schema is over
        # a megabyte, `grep -q` exits on the first match, and the SIGPIPE that
        # gives the writer becomes a pipeline failure under `set -o pipefail` —
        # which reads here as "every method is missing".
        # CodexAppServerClient: initialize, initialized, account/read,
        # account/rateLimits/read, model/list.
        # CodexTaskRunner: thread/start, thread/resume, turn/start, and the
        # notifications CodexRunObserver watches for.
        methods=(
            initialize initialized
            "account/read" "account/rateLimits/read" "model/list"
            "thread/start" "thread/resume" "turn/start"
            "turn/completed" "item/agentMessage/delta"
        )
        missing=()
        for method in "${methods[@]}"; do
            if ! grep -qrF -- "\"$method\"" "$schema_dir"; then
                missing+=("$method")
            fi
        done

        if [ ${#missing[@]} -eq 0 ]; then
            pass "all ${#methods[@]} App Server methods still in the protocol schema"
        else
            fail "${#missing[@]} method(s) gone from the protocol: ${missing[*]}"
            note "Fix CodexAppServerClient.swift and/or CodexTaskRunner.swift:148"
        fi
    else
        warn "could not generate the App Server protocol schema"
        note "Method-name drift is unchecked on this Codex version."
    fi
    rm -rf "$schema_dir"
fi

# --- 8. jq ------------------------------------------------------------------

section "Host tools"

if [ -x /usr/bin/jq ]; then
    pass "/usr/bin/jq present"
else
    warn "/usr/bin/jq missing — the default statusline will print nothing"
    note "Capture still works; only the passthrough display is affected."
fi

# --- Summary ----------------------------------------------------------------

printf '\n'
if [ "$failures" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m\n'
elif [ "$failures" -eq 0 ]; then
    printf '\033[33m%d warning(s), no failures.\033[0m\n' "$warnings"
else
    printf '\033[31m%d failure(s), %d warning(s).\033[0m\n' "$failures" "$warnings"
fi

exit "$failures"
