# ABOUTME: Actor identity, narrative-budget and tmux window-title code that cs AND its hooks run. build.sh
# ABOUTME: folds this into bin/cs and writes it verbatim to hooks/cs-shared.sh for sourcing.

# Normalize an arbitrary identity string to a filesystem-safe slug.
_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-*$//'
}

# The raw identity driving a session, before slugging. Args: the session root
# (where git config is read) and its meta dir (where the pinned identity lives);
# either may be empty. Precedence: $CS_ACTOR > <meta>/local/identity > git
# user.email > git user.name > "unknown". if/elif/else, not three independent
# tests: a pinned identity file ends the search by EXISTING, so a blank pin
# resolves to "unknown" rather than falling through to git.
cs_actor_raw() {  # session_dir, meta_dir
    local sdir="${1:-}" meta="${2:-}" raw=""
    if [ -n "${CS_ACTOR:-}" ]; then
        raw="$CS_ACTOR"
    elif [ -n "$meta" ] && [ -f "$meta/local/identity" ]; then
        IFS= read -r raw < "$meta/local/identity" || true
    else
        local gitdir="${sdir:-.}"
        raw=$(git -C "$gitdir" config user.email 2>/dev/null || true)
        [ -z "$raw" ] && raw=$(git -C "$gitdir" config user.name 2>/dev/null || true)
    fi
    [ -z "$raw" ] && raw="unknown"
    printf '%s\n' "$raw"
}

# Resolve the current actor as a slug. With a session_dir arg, resolve the
# pinned identity and git config from that dir (callers may run before
# CLAUDE_SESSION_META_DIR is exported). Without, use env + cwd.
cs_actor_slug() {
    local sdir="${1:-}" meta=""
    if [ -n "$sdir" ]; then
        meta="$sdir/.cs"
    else
        meta="${CLAUDE_SESSION_META_DIR:-}"
    fi
    _slugify "$(cs_actor_raw "$sdir" "$meta")"
}

# 224 KiB budget, 112 KiB tail. The ceiling is the Read tool's: it refuses a
# file over 256 KiB, and the resume reads the live narrative in one call, so a
# file past that size cannot be read in full at all. The budget sits under the
# ceiling with room for the appends made while the over-budget warning is on
# screen and before anyone rotates. The tail is what a resume actually costs;
# sections run about 2 KB and an active day produces 60-odd of them, so 112 KiB
# is most of a day. The 2:1 ratio keeps rotation infrequent: a full tail's
# worth must accumulate again before the next one.
CS_NARRATIVE_MAX_DEFAULT=229376
CS_NARRATIVE_KEEP_DEFAULT=114688

# A positive integer override, else the default. Empty, non-numeric and zero
# in any spelling (0, 00) all fall back: a zero budget would rotate on every
# run. The zero check runs on the number, not the text, and the number is
# decimal: a leading zero would reach the callers' arithmetic as an octal
# literal, and `08` aborts it. Sixteen digits or more fall back too: bash
# arithmetic wraps past 64 bits, and a wrapped budget is a silent wrong one.
_narrative_budget() {  # value, default
    local n
    case "${1:-}" in ''|*[!0-9]*|????????????????*) echo "$2"; return;; esac
    n=$((10#$1))
    if [ "$n" -gt 0 ]; then echo "$n"; else echo "$2"; fi
}

# Names a tmux window after every cs session running in its panes: "cs: a | b",
# in pane order, each name once. Under iTerm's tmux integration the window name
# is the tab's title, and one window holds every pane of a tab, so a single
# session writing its own name took the tab from the other. Each pane records
# its session in the pane option @cs_session; an empty name releases the pane.
# A named window is locked against Claude Code's own titles, as the launch
# locks it: a /clear releases the window and claims it back, and the claim must
# lock it again. With no cs session left it names itself again. Every tmux call
# is best-effort: a title must never fail a launch or a hook. The claim, the
# read of every claim and the rename run under the window's lock, since panes
# claim at the same moment (a layout restore, two /clears) and a rename written
# from a read before another pane's claim would drop that pane's name.
cs_tmux_title_window() {  # pane, session name ("" releases the pane)
    local pane="$1" name="$2" names lock
    [ -n "$pane" ] || return 0
    lock=$(_cs_tmux_title_lock "$pane")
    if [ -n "$name" ]; then
        tmux set-option -p -t "$pane" @cs_session "$name" 2>/dev/null || true
    else
        tmux set-option -p -u -t "$pane" @cs_session 2>/dev/null || true
    fi
    names=$(tmux list-panes -t "$pane" -F '#{@cs_session}' 2>/dev/null \
        | awk 'NF && !seen[$0]++ { out = out (out == "" ? "" : " | ") $0 } END { print out }') || names=""
    if [ -n "$names" ]; then
        tmux rename-window -t "$pane" "cs: $names" 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-rename off 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-set-title off 2>/dev/null || true
    else
        tmux set-window-option -t "$pane" automatic-rename on 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-rename on 2>/dev/null || true
        tmux set-window-option -t "$pane" allow-set-title on 2>/dev/null || true
    fi
    [ -z "$lock" ] || { rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null; } || true
}

# Takes the lock on a pane's window and prints its directory: a directory per
# tmux server and window under $TMPDIR, made by mkdir (atomic, and bash 3.2 has
# no flock), holding the holder's pid. A holder whose pid is gone died holding
# it, and the lock is taken over at once; a lock with no pid after a second is
# one whose holder died between the mkdir and the write, and is taken over too.
# A live holder is waited for, since a call is a few tmux round trips (385 ms
# measured on a loaded machine, so six panes queue for two seconds), but for no
# more than five seconds: past that the title is written without the lock, as
# a title must never stall a hook. Prints nothing when it holds nothing.
_cs_tmux_title_lock() {  # pane
    local key lock holder start=$SECONDS
    key=$(tmux display-message -p -t "$1" '#{socket_path}#{window_id}' 2>/dev/null) || key=""
    [ -n "$key" ] || return 0
    lock="${TMPDIR:-/tmp}/cs-title-$(printf '%s' "$key" | tr -c 'A-Za-z0-9@_.-' '_').lock"
    until mkdir "$lock" 2>/dev/null; do
        holder=""
        { read -r holder < "$lock/pid"; } 2>/dev/null || true
        if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } \
            || { [ -z "$holder" ] && [ $((SECONDS - start)) -ge 2 ]; }; then
            rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null
            start=$SECONDS
            continue
        fi
        [ $((SECONDS - start)) -lt 5 ] || return 0
        sleep 0.05
    done
    echo "$$" > "$lock/pid" 2>/dev/null || true
    printf '%s\n' "$lock"
}
