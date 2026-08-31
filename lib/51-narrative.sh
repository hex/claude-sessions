# ABOUTME: Rotates the current actor's narrative once it passes its byte budget: the
# ABOUTME: oldest '## ' sections move verbatim to .cs/narrative-archive/. Backs 'cs -narrative'.

CS_NARRATIVE_MAX_DEFAULT=131072
CS_NARRATIVE_KEEP_DEFAULT=65536

# A positive integer override, else the default. Empty, non-numeric and zero all
# fall back: a zero budget would rotate on every run.
_narrative_budget() {  # value, default
    case "${1:-}" in ''|*[!0-9]*|0) echo "$2";; *) echo "$1";; esac
}

# One line per '## ' heading: the heading's byte offset, a space, the heading.
# LC_ALL=C makes awk's length() count bytes, so offsets survive multibyte text
# (real headings carry an em dash).
_narrative_headings() {  # file
    LC_ALL=C awk 'BEGIN { off = 0 } { if (substr($0, 1, 3) == "## ") print off, $0; off += length($0) + 1 }' "$1"
}

# Byte offset of the first heading to KEEP: the earliest one with at most KEEP
# bytes between it and EOF. When even the final section is larger than KEEP,
# that final heading is the cut, so the tail is one oversized section rather
# than nothing.
_narrative_cut() {  # headings, size, keep
    local headings="$1" size="$2" keep="$3" off line
    while read -r off line; do
        [ -n "$off" ] || continue
        if [ $((size - off)) -le "$keep" ]; then
            echo "$off"
            return 0
        fi
    done <<EOF
$headings
EOF
    printf '%s\n' "$headings" | tail -1 | cut -d' ' -f1
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
    # Work from a snapshot: the cut is computed on bytes that cannot change under
    # us, and the live file is compared against that snapshot before it is rewritten.
    local snap="$meta_dir/memory/.narrative.$actor.rotate.$$"
    cp "$live" "$snap"
    # grep -c exits 1 on zero matches; under set -e -o pipefail that would end
    # cs instead of reaching the warning below, hence the || true.
    local headings count head_end cut
    headings=$(_narrative_headings "$snap")
    count=$(printf '%s\n' "$headings" | grep -c . || true)
    if [ "$count" -lt 2 ]; then
        rm -f "$snap"
        warn "narrative.$actor.md is over budget but has fewer than two sections; nothing can be archived without touching the tail"
        return 0
    fi
    head_end=$(printf '%s\n' "$headings" | head -1 | cut -d' ' -f1)
    cut=$(_narrative_cut "$headings" "$size" "$keep")
    if [ "$cut" -le "$head_end" ]; then
        rm -f "$snap"
        info "nothing to rotate: the first section already starts the retained tail"
        return 0
    fi

    local sections through
    sections=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' | grep -c . || true)
    through=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1 || true)
    [ -n "$through" ] || through="undated"

    local arch_dir="$meta_dir/narrative-archive/$actor"
    mkdir -p "$arch_dir"
    local body="$arch_dir/.body.$$"
    # head first, tail second: the bounded producer runs to completion and the
    # consumer reads all of it. The other order lets head close the pipe early
    # and tail die of SIGPIPE, which pipefail turns into a failed rotation on
    # any file whose kept tail is larger than the pipe buffer.
    head -c "$cut" "$snap" | tail -c +$((head_end + 1)) > "$body"
    local blob chunk chunk_tmp
    blob=$(git hash-object "$body" | cut -c1-8)
    chunk="$arch_dir/$through-$blob.md"
    chunk_tmp="$arch_dir/.$through-$blob.md.tmp"
    {
        printf '<!-- rotated from narrative.%s.md: %s sections through %s -->\n' "$actor" "$sections" "$through"
        printf '<!-- verbatim copy of the sections that preceded the live tail; never edited -->\n\n'
        cat "$body"
    } > "$chunk_tmp"
    rm -f "$body"
    mv "$chunk_tmp" "$chunk"

    # The live file must still open with the same bytes the snapshot did up to the
    # cut; a peer merge or an edit inside the archived run means the cut no longer
    # describes this file.
    if ! cmp -s -n "$cut" "$snap" "$live"; then
        rm -f "$snap" "$chunk"
        error "narrative.$actor.md changed during rotation; run cs -narrative rotate again"
    fi
    local live_tmp="$meta_dir/memory/.narrative.$actor.md.tmp"
    { head -c "$head_end" "$snap"; tail -c +$((cut + 1)) "$live"; } > "$live_tmp"
    mv "$live_tmp" "$live"
    rm -f "$snap"

    local archived_kb now_kb
    archived_kb=$(( (cut - head_end) / 1024 ))
    now_kb=$(( $(wc -c < "$live" | tr -d ' ') / 1024 ))
    echo "rotated $sections sections (${archived_kb} KB) -> .cs/narrative-archive/$actor/$(basename "$chunk"); live file now ${now_kb} KB"
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
