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

# More than one item shares this service name: the login, plus an
# MCP-server-token item that carries no claudeAiOauth. Checking only the first
# match reported a broken credential on a machine that was fine — the same bug
# ClaudeKeychain.decode now avoids by selecting on content.
accounts="$(security dump-keychain 2>/dev/null | awk '
    /^keychain: / { if (want && acct != "") print acct; want = 0; acct = "" }
    /"acct"<blob>="/ {
        line = $0
        sub(/.*"acct"<blob>="/, "", line)
        sub(/"[[:space:]]*$/, "", line)
        acct = line
    }
    /"svce"<blob>="Claude Code-credentials"/ { want = 1 }
    END { if (want && acct != "") print acct }
')"

if [ -z "$accounts" ] && security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    # Listed nowhere we can enumerate (a non-default keychain, say), but a
    # direct read still finds it. Fall back to the unscoped lookup.
    accounts="$(printf '\n')"
fi

if [ -n "$accounts" ]; then
    login_blob=""
    login_acct=""
    any_readable=0
    item_count=0

    while IFS= read -r acct; do
        item_count=$((item_count + 1))
        if [ -n "$acct" ]; then
            blob="$(security find-generic-password -s "Claude Code-credentials" -a "$acct" -w 2>/dev/null || true)"
        else
            blob="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
        fi
        [ -n "$blob" ] && any_readable=1
        if printf '%s' "$blob" | grep -q "claudeAiOauth"; then
            login_blob="$blob"
            login_acct="$acct"
        fi
    done <<EOF
$accounts
EOF

    if [ "$any_readable" -eq 0 ]; then
        warn "keychain item exists but could not be read without prompting"
        note "Expected when Tokenmax is ad-hoc signed; see Makefile:12"
    elif [ -n "$login_blob" ]; then
        pass "credential item present and still shaped as claudeAiOauth (account: ${login_acct:-default})"
        [ "$item_count" -gt 1 ] && note "$item_count items share this service name; Tokenmax picks the one carrying claudeAiOauth"
        for key in accessToken refreshToken subscriptionType; do
            if ! printf '%s' "$login_blob" | grep -q "$key"; then
                fail "claudeAiOauth.$key missing — ClaudeKeychain.decode will return nil"
            fi
        done
    else
        fail "no item under this service contains claudeAiOauth ($item_count checked)"
        note "Quota display will break. Fix ClaudeKeychain.swift (Payload/decode)"
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

# --- 7. jq ------------------------------------------------------------------

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
