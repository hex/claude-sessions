# ABOUTME: Rotates the current actor's narrative once it passes its byte budget: the
# ABOUTME: oldest '## ' sections move verbatim to .cs/narrative-archive/. Backs 'cs -narrative'.

CS_NARRATIVE_MAX_DEFAULT=131072
CS_NARRATIVE_KEEP_DEFAULT=65536

# A positive integer override, else the default. Empty, non-numeric and zero all
# fall back: a zero budget would rotate on every run.
_narrative_budget() {  # value, default
    case "${1:-}" in ''|*[!0-9]*|0) echo "$2";; *) echo "$1";; esac
}

# Archive the oldest sections of this actor's narrative when the file is over
# CS_NARRATIVE_MAX_BYTES, leaving a tail of about CS_NARRATIVE_KEEP_BYTES.
rotate_narrative() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ] || [ ! -d "${CLAUDE_SESSION_META_DIR}" ]; then
        error "cs -narrative rotate must be run from inside a cs session"
    fi
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}"
    local actor
    actor=$(cs_actor_slug "$session_dir")
    local live="$meta_dir/memory/narrative.$actor.md"
    [ -f "$live" ] || error "No narrative for actor $actor at $live"

    local max keep size
    max=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
    keep=$(_narrative_budget "${CS_NARRATIVE_KEEP_BYTES:-}" "$CS_NARRATIVE_KEEP_DEFAULT")
    size=$(wc -c < "$live" | tr -d ' ')
    if [ "$size" -le "$max" ]; then
        info "nothing to rotate: narrative.$actor.md is $((size / 1024)) KB (budget $((max / 1024)) KB)"
        return 0
    fi
    error "rotation not implemented yet"
}

# Dispatcher for cs -narrative
run_narrative() {
    local sub="${1:-}"
    case "$sub" in
        rotate)
            rotate_narrative
            ;;
        *)
            error "Usage: cs -narrative rotate   # from inside a session"
            ;;
    esac
}
