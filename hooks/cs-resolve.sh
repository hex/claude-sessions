#!/usr/bin/env bash
# ABOUTME: Resolves the cs session for a hook, from the env or from the cwd
# ABOUTME: Sourced by every hook; also carries JSONL tail repair. Not a hook itself

# Claude Code front ends differ in what they can hand a hook. The CLI is
# launched by `cs`, which exports the session contract before exec, so a hook
# inherits it. The desktop app spawns sessions itself: CLAUDE_ENV_FILE is
# offered to SessionStart and writes to it succeed, but nothing propagates to
# the Bash tool or to later hooks, so no hook can publish the contract to the
# rest of the session. What every front end does supply is the directory the
# session is open on (CLAUDE_PROJECT_DIR, and `cwd` in the hook input), and a
# cs session is identifiable on disk by its .cs/ directory.
#
# So: trust the env when it is there, and otherwise find the session the same
# way a person would, by looking at where we are.

# Resolve the session and export the contract. Returns 0 when a session was
# found, non-zero otherwise, leaving the caller's own decline path to run
# (hooks decline differently: exit 0, an approve payload, a JSON verdict).
cs_resolve_session() {  # [hook_input_json]
    local input="${1:-}" start="" dir="" name=""

    # Env first: the CLI path resolves here and never reaches the walk below.
    # The disabled marker is the one thing that does apply to it as well, and
    # deliberately: an opt-out that silenced one front end but not the other
    # would be a worse rule than "this directory is not a cs session".
    if [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]; then
        [ -d "$CLAUDE_SESSION_DIR" ] || return 1
        : "${CLAUDE_SESSION_META_DIR:=$CLAUDE_SESSION_DIR/.cs}"
        export CLAUDE_SESSION_META_DIR
        _cs_session_is_enabled "$CLAUDE_SESSION_DIR" || return 1
        CS_RESOLVED_FROM=env
        export CS_RESOLVED_FROM
        return 0
    fi

    # Prefer CLAUDE_PROJECT_DIR: it names the folder the session was opened on
    # and stays constant, where a hook input's cwd can follow the conversation.
    start="${CLAUDE_PROJECT_DIR:-}"
    if [ -z "$start" ] && [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
        start=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
    fi
    # Deliberately no $PWD fallback. A hook's working directory is whatever the
    # front end happened to leave it at, not a statement about which session is
    # open, so resolving from it would bind a hook to a session nobody asked
    # for — including any tool run from inside a session checkout.
    [ -n "$start" ] || return 1
    [ -d "$start" ] || return 1

    dir=$(_cs_find_session_root "$start") || return 1
    [ -n "$dir" ] || return 1
    _cs_session_is_enabled "$dir" || return 1

    name=$(_cs_session_name "$dir")

    CLAUDE_SESSION_DIR="$dir"
    CLAUDE_SESSION_META_DIR="$dir/.cs"
    CLAUDE_SESSION_NAME="$name"
    # Which path resolved matters downstream: only a cs launch owns the
    # session lock, so a hook that got here by walking must not remove it.
    CS_RESOLVED_FROM=walk
    export CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_SESSION_NAME CS_RESOLVED_FROM
    return 0
}

# Walk up looking for the .cs/ that marks a session root. The nearest one wins,
# so a session cloned inside another session belongs to itself. Stops at $HOME
# and at / so an unrelated .cs far up the tree cannot capture a stray folder.
_cs_find_session_root() {  # start_dir
    local d
    d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    local home_p
    home_p=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || printf '/nonexistent')
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        # Boundary before the marker test, so $HOME itself is never a session
        # root: a stray ~/.cs would otherwise adopt every project directly under
        # home into a phantom session named after the home directory.
        [ "$d" = "$home_p" ] && return 1
        if [ -d "$d/.cs" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# A session opts out of hook behaviour with .cs/local/disabled. Before this
# resolver a bare `claude` in a session dir was cs-blind; the marker restores
# that on request rather than by accident.
_cs_session_is_enabled() {  # session_dir
    [ -f "$1/.cs/local/disabled" ] && return 1
    return 0
}

# The name a session is known by is not always its basename: `cs -adopt` links
# a chosen name at an unrelated project path, and the link is invisible from the
# directory this walk arrives at. Adoption records the name in machine-local
# state, and opening an adopted session through cs rewrites it there, so a
# session adopted before cs wrote the key picks it up on its next open.
#
# Ordinary sessions record nothing: such a session IS its directory, so the
# basename is the answer, and a recorded name would outrank it while stale the
# moment the directory was renamed.
_cs_session_name() {  # session_dir
    local n=""
    if [ -f "$1/.cs/local/state" ]; then
        n=$(awk '/^session_name:/ { print $2; exit }' "$1/.cs/local/state" 2>/dev/null || true)
    fi
    [ -n "$n" ] || n=$(basename "$1")
    printf '%s\n' "$n"
}

# Terminate a JSONL file whose last line lost its newline to an interrupted
# write, so the next `>>` starts a fresh line instead of splicing two records
# onto one. The tolerant per-line reader (`fromjson? // empty` in
# run_conversations) drops a spliced line whole, losing the torn record AND the
# intact one appended after it. Shape shared with bin/cs's _terminate_jsonl —
# hooks cannot source bin/cs.
_cs_terminate_jsonl() {  # file
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
    printf '\n' >> "$1" 2>/dev/null || true
}
