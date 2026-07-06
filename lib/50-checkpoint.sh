# ABOUTME: Labelled state checkpoints (save/list/show) and the prose-slop linter.
# ABOUTME: Backs 'cs -checkpoint' and 'cs -lint'.

get_short_hostname() {
    hostname | cut -d. -f1
}

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

# Deterministic blocklist: multi-word, distinctive AI-slop phrases that measured
# ZERO occurrences across the real session corpus, so blocking on them is safe.
# The FULL stop-slop taxonomy (including single-word adverbs and lazy extremes)
# lives in the prose-hygiene skill and is enforced by the /summary and /wrap judge.
# Single-word tells (just, really, actually, every, always, never...) are
# DELIBERATELY excluded here: they occur 50-160+ times in legitimate technical
# prose, so a blocking regex on them would be unusable. They are judge-only by design.
# Phrases reworded from the stop-slop skill (github.com/hardikpandya/stop-slop, MIT).
PROSE_SLOP_PHRASES=(
    "it's worth noting"
    "at the end of the day"
    "needless to say"
    "the uncomfortable truth"
    "let that sink in"
    "make no mistake"
    "in today's fast-paced"
    "in a world where"
    "last but not least"
    "rest assured"
    "plot twist"
    "when all is said and done"
    "the fact of the matter"
    "without a doubt"
    "here's the thing"
    "let me be clear"
    "i'm going to be honest"
    "can we talk about"
    "here's what i find interesting"
    "here's the problem though"
    "this matters because"
    "here's why that matters"
    "you already know this"
    "but that's another post"
    "let me walk you through"
    "as we'll see"
    "i want to explore"
    "this is genuinely hard"
    "the reasons are structural"
    "the implications are significant"
    "the stakes are high"
    "the consequences are real"
    "at its core"
    "it turns out"
    "the truth is"
    "i'll say it again"
    "full stop."
    "here's what i mean"
    "think about it:"
    "and that's okay"
    "that's it. that's the"
    "the reality is"
    "when it comes to"
    "game-changer"
    "circle back"
    "deep dive"
    "actually matters"
    "in this section, we'll"
    "the rest of this essay"
    "dressed up as"
    "moving forward"
)

# Scan one file for lexical prose-slop tells outside fenced code blocks.
# Prints "<file>:<line>: <reason>" per violation. Returns 1 if any found, else 0.
lint_prose_file() {
    local file="$1"
    local lineno=0 in_fence=0 violations=0 line scan lower phrase
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Toggle fenced-code state on a line whose first non-space chars are ```
        if [[ "$line" =~ ^[[:space:]]*'```' ]]; then
            in_fence=$((1 - in_fence))
            continue
        fi
        [ "$in_fence" -eq 1 ] && continue
        # Inline code spans are quoted material, not prose: strip `...` pairs
        # before matching so a flagged character or phrase can be mentioned.
        scan="$line"
        while [[ "$scan" =~ \`[^\`]*\` ]]; do
            scan="${scan/"${BASH_REMATCH[0]}"/}"
        done
        # Em-dash (U+2014): a reliable AI tell with near-zero legitimate use in prose
        if [[ "$scan" == *—* ]]; then
            echo "$file:$lineno: em-dash (—); use a comma or period"
            violations=$((violations + 1))
        fi
        # Banned phrases, matched case-insensitively
        lower=$(printf '%s' "$scan" | tr '[:upper:]' '[:lower:]')
        for phrase in "${PROSE_SLOP_PHRASES[@]}"; do
            if [[ "$lower" == *"$phrase"* ]]; then
                echo "$file:$lineno: slop phrase: \"$phrase\""
                violations=$((violations + 1))
            fi
        done
    done < "$file"
    [ "$violations" -eq 0 ]
}

# `cs -lint <file>...` — deterministic prose linter for AI-slop tells.
# Exit codes: 0 clean, 1 violations found, 2 usage / unreadable file.
run_lint() {
    if [ $# -eq 0 ]; then
        echo "Usage: cs -lint <file>..." >&2
        return 2
    fi
    local file out had_violations=0 had_error=0 checked=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "cs -lint: cannot read '$file'" >&2
            had_error=1
            continue
        fi
        checked=$((checked + 1))
        if ! out=$(lint_prose_file "$file"); then
            printf '%s\n' "$out"
            had_violations=1
        fi
    done
    if [ "$had_error" -eq 1 ]; then
        return 2
    fi
    if [ "$had_violations" -eq 1 ]; then
        return 1
    fi
    info "cs -lint: no prose issues found ($checked file(s))"
    return 0
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
# <session>/.cs/local/: queue (one prompt/line), queue.done, queue.state
# (idle|armed|draining), queue.declined (epoch). Plain files so the standalone
# Stop hook can read them without bin/cs's helpers.

