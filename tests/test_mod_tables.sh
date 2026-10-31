#!/usr/bin/env bash
# ABOUTME: Tests that cs's mods hand Claude Code their toasts, notices, dialogs, replies and command rows from the tables each mod exports.
# ABOUTME: A design tool outside cs bundles those tables to draw what the engine draws for a mod, so a line written inline at a call site fails here.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
REPO="$SCRIPT_DIR/.."

setup() { :; }
teardown() { :; }

# cs and cs-update keep these lines in register.tsx (TOASTS, ASKS, LOGS,
# REPLIES, COMMANDS); cs-feed keeps its own in words.ts. A line a call site
# writes inline reaches the screen but not the exported table, so every call
# site that hands the engine one names its table instead. Comment lines are
# skipped.
WORD_SITES="
mods/cs/hooks/register.tsx
mods/cs-update/hooks/register.tsx
mods/cs-feed/hooks/register.tsx
mods/cs-feed/hooks/session.ts
mods/cs-panel/hooks/register.tsx
mods/cs-panel/hooks/draw.tsx
mods/cs-panel/hooks/settings.ts
"
test_mods_hand_the_engine_their_lines_from_their_tables() {
    local f inline=""
    for f in $WORD_SITES; do
        [ -f "$REPO/$f" ] || { echo "  FAIL: $f is gone; name the file that hands the engine its lines"; return 1; }
        inline="$inline$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$REPO/$f" \
            | grep -nE '\$\.ui\.(toast|log|ask)\([[:space:]]*[`'"'"'"]|\$\.command\.register\([[:space:]]*\{|return \{ text: [`'"'"'"]' \
            | sed "s|^|$f:|")"
    done
    assert_eq "" "$inline" "no toast, log, dialog, reply or command registration is written inline" || return 1
}

run_test test_mods_hand_the_engine_their_lines_from_their_tables

report_results
