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

# Pre-window checks that must pass BEFORE the seed is written, so a refused
# spawn never leaves a pending seed behind.
_spawn_precheck() {  # name
    local name="$1"
    command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 || error "cs -spawn needs tmux"
    if session_is_live "$SESSIONS_ROOT/$name/.cs"; then
        error "Session $name is already live"
    fi
    if _tmux has-session -t cs 2>/dev/null; then
        local owned
        owned=$(_tmux show-option -t cs -v @cs_managed 2>/dev/null || true)
        [ "$owned" = "1" ] || error "A tmux session named 'cs' exists but was not created by cs; close or rename it"
        if _tmux list-windows -t cs -F '#{window_name}' 2>/dev/null | grep -Fxq "$name"; then
            error "A window named $name already exists in tmux session cs"
        fi
    fi
}

_spawn_window() {  # name
    local name="$1" cmd wid
    cmd="$(_sq "$(_cs_self)") $(_sq "$name")"
    if ! _tmux has-session -t cs 2>/dev/null; then
        if wid=$(_tmux new-session -d -s cs -n "$name" -P -F '#{window_id}' "$cmd" 2>/dev/null); then
            _tmux set-option -t cs @cs_managed 1
            info "spawned $name in tmux session cs (window $wid). Attach: tmux attach -t cs"
            return 0
        fi
        # A concurrent spawner won the new-session race: fall through and add
        # a window to the session it just created.
    fi
    wid=$(_tmux new-window -t cs -n "$name" -P -F '#{window_id}' "$cmd") \
        || error "tmux new-window failed for $name"
    info "spawned $name in tmux session cs (window $wid). Attach: tmux attach -t cs"
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
