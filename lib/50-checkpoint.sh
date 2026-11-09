# ABOUTME: Labelled state checkpoints (save/list/show).
# ABOUTME: Backs 'cs -checkpoint'.

# A file's mtime as local date and time, "-" when it cannot be read. GNU stat
# is asked first, as _epoch_mtime does, and its answer keeps the seconds.
get_file_mtime() {
    local file="$1" mtime
    if mtime=$(stat -c "%y" "$file" 2>/dev/null); then
        printf '%s\n' "${mtime%%.*}"
    else
        stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null || echo "-"
    fi
}

# Slugify a label for use as a filename segment
_slugify_label() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40
}

# Where checkpoints live: .cs/private/checkpoints in an encrypted session,
# .cs/checkpoints in every other. A checkpoint copies the narrative, so a
# narrative behind a .cs/memory link with no .cs/private beside it has no
# private place to go (rc 2); a dangling .cs/private is a locked vault (rc 1).
_checkpoints_dir() {  # meta_dir
    if [ -L "$1/private" ] || [ -e "$1/private" ]; then
        [ -d "$1/private" ] || return 1
        printf '%s\n' "$1/private/checkpoints"
    elif [ -L "$1/memory" ]; then
        return 2
    else
        printf '%s\n' "$1/checkpoints"
    fi
}

# Names why _checkpoints_dir failed; returns when it did not.
_refuse_checkpoints_dir() {  # rc, meta_dir
    case "$1" in
        0) ;;
        1) error "this session keeps its checkpoints in encrypted storage that is not mounted (.cs/private $(cs_private_state "$2")). Mount it, then retry." ;;
        2) error "this session's narrative lives on encrypted storage (.cs/memory is a link), and .cs/private is not there to hold the checkpoint. Link .cs/private into the vault, then retry." ;;
        *) error "_checkpoints_dir returned $1 for $2" ;;
    esac
}

# Save a labelled checkpoint of the current session state
save_checkpoint() {
    local label="$*"

    if [ -z "$label" ]; then
        error "Usage: cs -checkpoint \"<label>\"   # from inside a session"
    fi

    if [ -z "${CLAUDE_SESSION_NAME:-}" ] || [ -z "${CLAUDE_SESSION_META_DIR:-}" ] || [ ! -d "${CLAUDE_SESSION_META_DIR}" ]; then
        error "cs -checkpoint must be run from inside a cs session"
    fi

    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local checkpoints_dir rc=0
    checkpoints_dir=$(_checkpoints_dir "$meta_dir") || rc=$?
    _refuse_checkpoints_dir "$rc" "$meta_dir"
    mkdir -p "$checkpoints_dir"

    local stamp slug filename checkpoint_path
    stamp=$(date '+%Y-%m-%d-%H%M%S')
    slug=$(_slugify_label "$label")
    filename="${stamp}-${slug}.md"
    checkpoint_path="$checkpoints_dir/$filename"

    # Gather current state
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}"
    local git_head git_status_lines
    git_head=$(git -C "$session_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    git_status_lines=$(git -C "$session_dir" status --porcelain 2>/dev/null | head -20 || true)

    # Write checkpoint file
    {
        echo "# Checkpoint: $label"
        echo ""
        echo "**Timestamp:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Session:** $CLAUDE_SESSION_NAME"
        echo "**HEAD:** $git_head"
        echo ""
        if [ -n "$git_status_lines" ]; then
            echo "## Uncommitted changes"
            echo ""
            echo '```'
            echo "$git_status_lines"
            echo '```'
            echo ""
        fi
        local _nf
        for _nf in "$meta_dir"/memory/narrative*.md; do
            [ -f "$_nf" ] || continue
            echo "## Narrative snapshot ($(basename "$_nf"))"
            echo ""
            cat "$_nf"
            echo ""
        done
    } > "$checkpoint_path"

    # Append to timeline.jsonl
    local timeline_file="$meta_dir/timeline.jsonl"
    local timeline_branch
    timeline_branch=$(git -C "$session_dir" branch --show-current 2>/dev/null || echo "")
    # The label and the file name derived from it are topic text; an
    # encrypted session's plaintext timeline records only that a checkpoint
    # was taken.
    local sealed=false
    [ "$checkpoints_dir" = "$meta_dir/private/checkpoints" ] && sealed=true
    _append_record "$timeline_file" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "checkpoint" \
           --arg label "$label" \
           --arg file "$filename" \
           --arg branch "$timeline_branch" \
           --argjson sealed "$sealed" \
           'if $sealed then {ts: $ts, event: $event, branch: $branch}
            else {ts: $ts, event: $event, label: $label, file: $file, branch: $branch} end'

    info "Checkpoint saved: $filename"
    echo "  Label: $label"
    echo "  Path: $checkpoint_path"
}

# List all checkpoints for the current session
list_checkpoints() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -checkpoint list must be run from inside a cs session"
    fi
    local checkpoints_dir rc=0
    checkpoints_dir=$(_checkpoints_dir "$CLAUDE_SESSION_META_DIR") || rc=$?
    _refuse_checkpoints_dir "$rc" "$CLAUDE_SESSION_META_DIR"
    if [ ! -d "$checkpoints_dir" ] || [ -z "$(ls -A "$checkpoints_dir" 2>/dev/null)" ]; then
        info "No checkpoints yet. Save one with: cs -checkpoint \"<label>\""
        return 0
    fi
    echo "Checkpoints for session: $CLAUDE_SESSION_NAME"
    echo ""
    # .cs/checkpoints is tracked in a plaintext session, so a clone chooses
    # the file names and the labels: a name prints plain, a label without its
    # control bytes.
    local f name label
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        name=$(_cs_plain_name "$(basename "$f" .md)" 160)
        label=$(grep -m1 '^# Checkpoint:' "$f" 2>/dev/null | sed 's/^# Checkpoint: //' | _scrub_controls || echo "-")
        printf "  %s\n    %s\n" "$name" "$label"
    done < <(ls -t "$checkpoints_dir"/*.md 2>/dev/null)
}

# Print a specific checkpoint file
show_checkpoint() {
    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: cs -checkpoint show <checkpoint-name>"
    fi
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -checkpoint show must be run from inside a cs session"
    fi
    local checkpoints_dir rc=0
    checkpoints_dir=$(_checkpoints_dir "$CLAUDE_SESSION_META_DIR") || rc=$?
    _refuse_checkpoints_dir "$rc" "$CLAUDE_SESSION_META_DIR"
    local path="$checkpoints_dir/${name}.md"
    if [ ! -f "$path" ]; then
        error "Checkpoint not found: $name"
    fi
    # A clone chooses what the file says too.
    _scrub_controls < "$path"
}

# Dispatcher for cs -checkpoint subcommand
run_checkpoint() {
    local sub="${1:-}"
    case "$sub" in
        list|ls)
            list_checkpoints
            ;;
        show)
            shift
            show_checkpoint "${1:-}"
            ;;
        "")
            error "Usage: cs -checkpoint \"<label>\" | list | show <name>"
            ;;
        *)
            save_checkpoint "$@"
            ;;
    esac
}

# --- Task queue (cs -queue) ---------------------------------------------------
# Machine-local queue of prompts drained by the Stop hook. Files live in
# <session>/.cs/local/ (.cs/private/ in an encrypted session): queue/ (one
# file per task, staged via queue.tmp/),
# queue.done, queue.state (idle|armed|draining), queue.mode (subagents|workflow,
# absent to run tasks in the conversation), queue.current (the task the drain
# last handed out), queue.failed (a reported failure the drain has not parked
# on yet), queue.accepted (message ids cs -queue accept already queued).
# Plain files so the standalone Stop hook can read them without bin/cs's
# helpers.

