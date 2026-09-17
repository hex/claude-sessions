# ABOUTME: Backs 'cs -spawn': open a session in the cs-owned tmux session,
# ABOUTME: optionally staging tasks the launch path arms on open.

# Every tmux call goes through this wrapper; tests point CS_TMUX_BIN at a fake.
_tmux() {
    "${CS_TMUX_BIN:-tmux}" "$@"
}

# Single-quote encode one word for a shell command line handed to tmux.
_sq() {  # text
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Absolute path of the running cs binary (the tmux server's PATH may lack
# ~/.local/bin, so the window command must not rely on lookup).
_cs_self() {
    case "$0" in
        */*) printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")";;
        *)   command -v -- "$0" 2>/dev/null || printf '%s' "$0";;
    esac
}

# Delete any staged or stale seed and brief for a name. Called when the
# session is deleted: a leftover seed would block re-spawning the name and arm
# a future same-name session with dead tasks and a dead brief.
_spawn_discard_seeds() {  # name
    rm -f "$SESSIONS_ROOT/.spawn/$1.seed" "$SESSIONS_ROOT/.spawn/$1.seed.stale" \
          "$SESSIONS_ROOT/.spawn/$1.brief.md" "$SESSIONS_ROOT/.spawn/$1.brief.md.stale"
}

# True when the tmux session named 'cs' carries cs's ownership stamp. Only
# meaningful once has-session has confirmed exact 'cs' exists: the plain '-t cs'
# target is required because tmux 3.6a rejects '=' anchors on the options
# commands. Shared by _spawn_precheck (errors on a foreign session) and the
# doctor's spawn check (warns), so the @cs_managed contract lives in one place.
_cs_tmux_managed() {
    [ "$(_tmux show-option -t cs -v @cs_managed 2>/dev/null || true)" = "1" ]
}

# Pre-window checks that must pass BEFORE the seed is written, so a refused
# spawn never leaves a pending seed behind.
_spawn_precheck() {  # name
    local name="$1"
    command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 || error "cs -spawn needs tmux"
    if session_is_live "$SESSIONS_ROOT/$name/.cs"; then
        error "Session $name is already live"
    fi
    if _tmux has-session -t =cs 2>/dev/null; then
        _cs_tmux_managed || error "A tmux session named 'cs' exists but was not created by cs; close or rename it"
        # Best-effort tidiness check only. session_is_live above is the real
        # guard against double-launching a session; tmux automatic-rename can
        # rename a window out from under this name match, and the only cost of a
        # miss is a duplicate window name in the cs session, never a second live
        # launch. Do not add locking here for that benign case.
        if _tmux list-windows -t =cs -F '#{window_name}' 2>/dev/null | grep -Fxq "$name"; then
            error "A window named $name already exists in tmux session cs"
        fi
    fi
}

# How to reach the cs tmux session. tmux attach refuses to nest, so a caller
# already inside tmux is told to switch-client instead.
_spawn_attach_hint() {
    if [ -n "${TMUX:-}" ]; then
        printf 'tmux switch-client -t cs'
    else
        printf 'tmux attach -t cs'
    fi
}

_spawn_window() {  # name
    local name="$1" cmd wid
    cmd="$(_sq "$(_cs_self)") $(_sq "$name")"
    # Try to create the cs session outright: tmux rejects a duplicate -s name,
    # so "already exists" and "a concurrent spawner just created it" collapse
    # into the same fallthrough to new-window.
    if wid=$(_tmux new-session -d -s cs -n "$name" -P -F '#{window_id}' "$cmd" 2>/dev/null); then
        # Plain target: tmux 3.6a rejects '=' anchors on the options commands;
        # exact 'cs' was just created by new-session, so this cannot misfire.
        _tmux set-option -t cs @cs_managed 1
        info "spawned $name in tmux session cs (window $wid). Attach: $(_spawn_attach_hint)"
        return 0
    fi
    wid=$(_tmux new-window -t =cs -n "$name" -P -F '#{window_id}' "$cmd") \
        || error "tmux new-window failed for $name"
    info "spawned $name in tmux session cs (window $wid). Attach: $(_spawn_attach_hint)"
}

run_spawn() {
    local name="" brief="" nl='
'
    local usage='Usage: cs -spawn <name> [--brief <file>] [--task "..."] ...'
    local tasks
    tasks=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --task)
                [ $# -ge 2 ] || error "--task needs a value"
                shift
                local t
                t="$(_trim "$1")"
                [ -n "$t" ] || error "cs -spawn --task needs a non-empty task"
                case "$t" in *"$nl"*) error "task bodies must be a single line (the queue's done log and listing are line-oriented)";; esac
                tasks+=("$t");;
            --brief)
                [ $# -ge 2 ] || error "--brief needs a file"
                shift
                [ -z "$brief" ] || error "cs -spawn takes one --brief"
                [ -f "$1" ] && [ -r "$1" ] || error "cs -spawn --brief: cannot read $1"
                [ -s "$1" ] || error "cs -spawn --brief: $1 is empty"
                brief="$1";;
            -*) error "Unknown option: $1. $usage";;
            *)
                [ -z "$name" ] || error "cs -spawn takes exactly one session name"
                name="$1";;
        esac
        shift
    done
    [ -n "$name" ] || error "$usage"
    if ! cs_split_worktree_name "$name"; then
        validate_session_name "$name"
    fi
    _spawn_precheck "$name"
    # A brief is staged with a seed even when there are no tasks: the seed
    # carries the spawner, which the brief's report-back line needs.
    if [ "${#tasks[@]}" -gt 0 ] || [ -n "$brief" ]; then
        local sdir="$SESSIONS_ROOT/.spawn" seed
        seed="$sdir/$name.seed"
        # The check-then-write below is deliberately unlocked. The tmp+mv makes
        # the write atomic, so two concurrent spawns of the same name resolve to
        # last-writer-wins with no torn or interleaved seed. Adding a lock would
        # buy nothing for that benign race.
        [ ! -f "$seed" ] || error "A pending spawn for $name exists: $seed"
        mkdir -p "$sdir"
        # Brief before seed: the launch treats the seed as the signal, so a
        # brief must never be missing once the seed is visible. A copy that
        # fails stops here, before the seed and the window: errexit does not
        # see a failed left operand, so the abort is explicit. The seed write
        # below is an AND list for the same reason, and it takes the staged
        # brief down with it: a brief left without its seed would be inherited
        # by the next spawn of this name, which asked for no brief at all.
        if [ -n "$brief" ]; then
            cp "$brief" "$sdir/$name.brief.md.tmp" \
                && mv "$sdir/$name.brief.md.tmp" "$sdir/$name.brief.md" \
                || { rm -f "$sdir/$name.brief.md.tmp"; error "cs -spawn --brief: cannot stage $brief in $sdir"; }
        fi
        {
            printf '%s\n' "${CLAUDE_SESSION_NAME:-}"
            # An empty array is unbound under bash 3.2's set -u, and a brief
            # alone leaves it empty; the guard expands to nothing in that case.
            local _t
            for _t in ${tasks[@]+"${tasks[@]}"}; do printf '%s\n' "$_t"; done
        } > "$seed.tmp" && mv "$seed.tmp" "$seed" \
            || { rm -f "$seed.tmp" "$sdir/$name.brief.md" 2>/dev/null || :; error "cs -spawn: cannot stage the seed in $sdir"; }
    fi
    _spawn_window "$name"
}
