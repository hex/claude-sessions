#!/usr/bin/env bash
# ABOUTME: Contract pins for the reference docs: env-var coverage and backend lists.
# ABOUTME: Derives its expectations from source rather than a hand-written list.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

REPO="$SCRIPT_DIR/.."

# README.md points at docs/configuration.md as "Every environment variable cs
# reads", so README is the promise and configuration.md is the payload. Deriving
# the required set from README rather than from a list in this file is the whole
# point: a variable documented in one place and not the other fails here without
# anyone remembering to update a pin.
#
# Deliberately NOT derived from a `${CS_*}` scan of lib/ and hooks/: that set
# includes internal plumbing (test seams, values cs exports to its own children)
# which is not a user contract, and promoting it to one is a product decision.
test_configuration_documents_every_env_var_the_readme_names() {
    local missing
    missing=$(comm -23 \
        <(grep -oE 'CS_[A-Z0-9_]+' "$REPO/README.md" | sort -u) \
        <(grep -oE 'CS_[A-Z0-9_]+' "$REPO/docs/configuration.md" | sort -u))
    if [ -n "$missing" ]; then
        echo "  FAIL: README names these but docs/configuration.md does not carry them:"
        printf '    %s\n' $missing
        return 1
    fi
    # Reachability: the comparison is worthless if either side reads empty.
    local count
    count=$(grep -coE 'CS_[A-Z0-9_]+' "$REPO/docs/configuration.md" | tr -d '[:space:]')
    [ "${count:-0}" -gt 5 ] \
        || { echo "  FAIL: configuration.md yielded $count env vars; the extraction is broken"; return 1; }
}

# The secrets backend name is spelled in the code that validates it plus three
# prose copies. `wcm` was absent from all three while the code accepted it.
test_every_backend_the_code_accepts_is_documented() {
    local backends f b
    # The validated set, from the one place that rejects anything else.
    # Read the alternation the validator rejects everything else against, and
    # split it. No hardcoded fallback: with one, a fourth backend added to the
    # code and omitted from the docs shipped green, which is the entire drift
    # class this test exists for. An extraction that finds nothing is a broken
    # test, not a passing one.
    backends=$(grep -oE '^[[:space:]]*keychain\|[a-z|]+\)' "$REPO/bin/cs-secrets" \
        | head -1 | tr -d ' )' | tr '|' ' ')
    [ -n "$backends" ] \
        || { echo "  FAIL: could not read the backend set from bin/cs-secrets"; return 1; }
    case "$backends" in
        *keychain*) ;;
        *) echo "  FAIL: extraction produced '$backends', which is not the backend set"; return 1 ;;
    esac
    for f in "$REPO/docs/secrets.md" "$REPO/docs/configuration.md" "$REPO/bin/cs-secrets"; do
        for b in $backends; do
            grep -qF "$b" "$f" \
                || { echo "  FAIL: $(basename "$f") never names the '$b' backend"; return 1; }
        done
    done
}

# The closing summary claimed hooks detect a session via CLAUDE_SESSION_NAME and
# are inert without it. cs-resolve.sh has a second arm that walks up from the
# opened directory, so a front end that exports nothing still activates them —
# and the page's own resolution section says so. Pin both halves: the false
# mechanism must stay gone, and the real one must stay stated.
test_hooks_doc_states_both_resolution_arms() {
    local doc="$REPO/docs/hooks.md"
    assert_file_not_contains "$doc" "detected via .CLAUDE_SESSION_NAME. environment variable" \
        "the env-var-only activation claim must not return" || return 1
    assert_file_contains "$doc" "walking up from the directory" \
        "the doc must state the arm that makes the claim false" || return 1
    assert_file_contains "$doc" "cs_resolve_session" \
        "and name the function that owns the contract" || return 1
    assert_file_contains "$doc" "CLAUDE_CODE_ENTRYPOINT" \
        "and the front-end test that keeps a terminal claude out of the walk" || return 1
}


# Rotation made "read all narratives on resume" false, and size made "read the
# live narratives" false too (one teammate file measured 801 KB): a resume reads
# its own narrative in full and a teammate's only from the line the digest
# names. No user-facing surface may say otherwise: the lib templates, the
# hooks, the commands, README and docs.
# lib/45-migrate.sh is exempt: migrate_narrative_resume_wording's grep/sed/awk
# patterns must name the dead sentence verbatim to find and rewrite it in files
# cs already wrote. That is a matcher, not a surface telling anyone to read
# every narrative.
test_no_surface_tells_a_resume_to_read_every_narrative() {
    local hits
    hits=$(grep -rniE "read all narrative|read all of them|reads all of them|everyone reads all|read the live narrative|reads the live files|read the live files" \
        "$REPO/lib" "$REPO/hooks" "$REPO/commands" "$REPO/README.md" "$REPO/docs"/*.md 2>/dev/null \
        | grep -v '/lib/45-migrate\.sh:' || true)
    if [ -n "$hits" ]; then
        echo "  FAIL: these surfaces still tell a resume to read every narrative:"
        printf '    %s\n' "$hits"
        return 1
    fi
}

run_test test_configuration_documents_every_env_var_the_readme_names
run_test test_every_backend_the_code_accepts_is_documented
run_test test_hooks_doc_states_both_resolution_arms
run_test test_no_surface_tells_a_resume_to_read_every_narrative

report_results
