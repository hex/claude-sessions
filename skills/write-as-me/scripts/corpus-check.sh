#!/usr/bin/env bash
# ABOUTME: Counts the entries in a built write-as-me corpus that are not the user's typing
# ABOUTME: Exits 1 when any class is present, so a rebuilt corpus can be checked on real transcripts
set -euo pipefail

CORPUS="${1:-${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice/corpus.md}"
[ -f "$CORPUS" ] || { echo "corpus-check: no corpus at $CORPUS" >&2; exit 2; }

# An entry is a "[project, YYYY-MM-DD]" line after a "---" line, then its text.
# The transcript body ends where the short-ack appendix begins.
awk '
    /^## Short-ack frequency/ { exit }
    prev == "---" && /^\[[^],]+, [0-9-]+\]$/ {
        entry++
        proj = substr($0, 2, index($0, ",") - 2)
        if (proj ~ /^-private-tmp-|^-tmp-|^-private-var-folders-|--cs-local-/) test_session++
        opening = 1; prev = $0; next
    }
    opening && /^Here is a note offered by a side agent:/ { side_note++ }
    opening && /^A side check by / { side_check++ }
    /<pasted_content id="/ && pasted_in != entry { tagged_paste++; pasted_in = entry }
    { opening = 0; prev = $0 }
    END {
        printf "side-agent notes: %d\nside checks: %d\ntagged pastes: %d\ntest-session entries: %d\n",
            side_note, side_check, tagged_paste, test_session
        exit (side_note + side_check + tagged_paste + test_session > 0)
    }
' "$CORPUS"
