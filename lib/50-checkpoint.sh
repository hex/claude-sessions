# ABOUTME: Labelled state checkpoints (save/list/show).
# ABOUTME: Backs 'cs -checkpoint'.

get_file_mtime() {
    local file="$1"
    if [[ "$OSTYPE" == darwin* ]]; then
        stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null || echo "-"
    else
        stat -c "%y" "$file" 2>/dev/null | cut -d. -f1 || echo "-"
    fi
}

# Slugify a label for use as a filename segment
_slugify_label() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40
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
    local checkpoints_dir="$meta_dir/checkpoints"
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
    _terminate_jsonl "$timeline_file"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "checkpoint" \
           --arg label "$label" \
           --arg file "$filename" \
           --arg branch "$timeline_branch" \
           '{ts: $ts, event: $event, label: $label, file: $file, branch: $branch}' \
        >> "$timeline_file" 2>/dev/null || true

    info "Checkpoint saved: $filename"
    echo "  Label: $label"
    echo "  Path: $checkpoint_path"
}

# List all checkpoints for the current session
list_checkpoints() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -checkpoint list must be run from inside a cs session"
    fi
    local checkpoints_dir="$CLAUDE_SESSION_META_DIR/checkpoints"
    if [ ! -d "$checkpoints_dir" ] || [ -z "$(ls -A "$checkpoints_dir" 2>/dev/null)" ]; then
        info "No checkpoints yet. Save one with: cs -checkpoint \"<label>\""
        return 0
    fi
    echo "Checkpoints for session: $CLAUDE_SESSION_NAME"
    echo ""
    local f name label
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        name=$(basename "$f" .md)
        label=$(grep -m1 '^# Checkpoint:' "$f" 2>/dev/null | sed 's/^# Checkpoint: //' || echo "-")
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
    local checkpoints_dir="$CLAUDE_SESSION_META_DIR/checkpoints"
    local path="$checkpoints_dir/${name}.md"
    if [ ! -f "$path" ]; then
        error "Checkpoint not found: $name"
    fi
    cat "$path"
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
# <session>/.cs/local/: queue/ (one file per task, staged via queue.tmp/),
# queue.done, queue.state (idle|armed|draining), queue.declined (epoch).
# Plain files so the standalone Stop hook can read them without bin/cs's
# helpers.

