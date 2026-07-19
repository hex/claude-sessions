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

# Delete any staged or stale seed for a name. Called when the session is
# deleted: a leftover seed would block re-spawning the name and arm a
# future same-name session with dead tasks.
_spawn_discard_seeds() {  # name
    rm -f "$SESSIONS_ROOT/.spawn/$1.seed" "$SESSIONS_ROOT/.spawn/$1.seed.stale"
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
        local owned
        # Plain target: tmux 3.6a rejects '=' anchors on the options commands,
        # and this only runs after has-session confirmed exact 'cs' exists,
        # so prefix matching cannot misfire.
        owned=$(_tmux show-option -t cs -v @cs_managed 2>/dev/null || true)
        [ "$owned" = "1" ] || error "A tmux session named 'cs' exists but was not created by cs; close or rename it"
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
    local name="" nl='
'
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
                case "$t" in *"$nl"*) error "task bodies must be a single line (the queue file is line-oriented)";; esac
                tasks+=("$t");;
            -*) error "Unknown option: $1. Usage: cs -spawn <name> [--task \"...\"] ...";;
            *)
                [ -z "$name" ] || error "cs -spawn takes exactly one session name"
                name="$1";;
        esac
        shift
    done
    [ -n "$name" ] || error "Usage: cs -spawn <name> [--task \"...\"] ..."
    if ! cs_split_worktree_name "$name"; then
        validate_session_name "$name"
    fi
    _spawn_precheck "$name"
    if [ "${#tasks[@]}" -gt 0 ]; then
        local sdir="$SESSIONS_ROOT/.spawn" seed
        seed="$sdir/$name.seed"
        # The check-then-write below is deliberately unlocked. The tmp+mv makes
        # the write atomic, so two concurrent spawns of the same name resolve to
        # last-writer-wins with no torn or interleaved seed. Adding a lock would
        # buy nothing for that benign race.
        [ ! -f "$seed" ] || error "A pending spawn for $name exists: $seed"
        mkdir -p "$sdir"
        {
            printf '%s\n' "${CLAUDE_SESSION_NAME:-}"
            local _t
            for _t in "${tasks[@]}"; do printf '%s\n' "$_t"; done
        } > "$seed.tmp" && mv "$seed.tmp" "$seed"
    fi
    _spawn_window "$name"
}
