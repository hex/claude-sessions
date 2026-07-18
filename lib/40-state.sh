# ABOUTME: Machine-local session state: UUID/color allocation, local-state read/write, actor identity.
# ABOUTME: Backs 'cs -whoami' and 'cs -who'.

_alloc_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    else
        error "no UUID generator available (need uuidgen, /proc/sys/kernel/random/uuid, or python3)"
    fi
}

# The 8 colors claude's /color slash command accepts (verified against the
# binary's own error message in claude 2.1.162). Anything else errors with
# "Invalid color X". Notably absent: teal, magenta, white, black, gray, hex.
CS_VALID_COLORS=(red blue green yellow purple orange pink cyan)

# Pick a random color from CS_VALID_COLORS. Used at session creation to give
# each cs session a distinct prompt-bar accent without user choice. Claude
# defaults to teal; cs randomizes so parallel sessions are visually distinct
# at a glance.
_alloc_random_color() {
    echo "${CS_VALID_COLORS[$((RANDOM % ${#CS_VALID_COLORS[@]}))]}"
}

# Machine-local session state lives in .cs/local/state as 'key: value' lines
# (claude_session_id, claude_session_color, last_resumed). It is gitignored
# (see create_session_gitignore) because these values legitimately differ per
# machine — recording them in the git-synced README caused merge conflicts
# whenever two machines resumed the same session.

# Read a key's value from a machine-local state file. Prints the value to
# stdout, or empty if absent or unreadable. Never errors. KEEP THE FORMAT IN
# SYNC WITH bin/cs-statusline's _read_session_color (a pure-bash copy on the
# render hot path) and hooks/session-start.sh's local_state_set.
_read_local_state() {
    local state="$1" key="$2"
    [ -f "$state" ] || return 0
    awk -v key="$key" '
        index($0, key ":") == 1 {
            sub(/^[^:]*:[[:space:]]*/, "")
            gsub(/"/, "")
            print
            exit
        }
    ' "$state" 2>/dev/null || true
}

# Write 'key: value' into a machine-local state file, replacing any existing
# line for that key. Creates .cs/local/ and the file on first write. Atomic
# (tmp+mv), idempotent.
_set_local_state() {
    local state="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$state")"
    local tmp="$state.tmp"
    {
        if [ -f "$state" ]; then
            awk -v key="$key" 'index($0, key ":") != 1' "$state"
        fi
        printf '%s: %s\n' "$key" "$value"
    } > "$tmp" && mv "$tmp" "$state"
}

# Return the path to claude's per-cwd transcript directory. Symlinks in the
# input are resolved via `pwd -P` so the encoding matches claude's own —
# macOS mktemp returns /var/folders/... which is a symlink to
# /private/var/folders/... and claude realpaths cwd before encoding.
# CS_TRANSCRIPTS_DIR overrides the base for tests (also used by doctor).
_claude_project_dir() {
    local cwd="$1"
    local resolved
    resolved=$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "$cwd" )
    printf '%s/%s\n' "${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}" \
        "$(_claude_encode_path "$resolved")"
}

# Discover claude's most-recently-modified transcript UUID under a project
# directory, or empty string if none. The newest transcript is what
# `claude --continue` would resume, so binding the session's recorded UUID
# to it makes `--resume <uuid>` equivalent to `--continue` on first contact.
# Takes the project dir (not cwd) so callers that already computed it via
# _claude_project_dir can avoid a second symlink resolution.
_discover_session_uuid_in() {
    local proj="$1"
    [ -d "$proj" ] || return 0
    local newest
    newest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 || true)
    [ -n "$newest" ] || return 0
    basename "$newest" .jsonl
}

# Append a rotated event to the tracked timeline: the durable link between
# the conversation being left and the one about to start. Shape shared with
# hooks/session-start.sh's rebind emitter (hooks cannot source bin/cs).
# Best-effort — a timeline failure must never break a launch.
_timeline_rotated() {  # session_dir, from, to, reason, [handoff]
    local session_dir="$1" from="$2" to="$3" reason="$4" handoff="${5:-}"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg from "$from" \
           --arg to "$to" \
           --arg reason "$reason" \
           --arg handoff "$handoff" \
           '{ts: $ts, event: "rotated", from: $from, to: $to, reason: $reason}
            + (if $handoff == "" then {} else {handoff: $handoff} end)' \
        >> "$session_dir/.cs/timeline.jsonl" 2>/dev/null || true
}

# Allocate a fresh UUID, rewrite the local state's claude_session_id to it, export
# CS_CLAUDE_SESSION_ID + CS_FRESH_REBIND, and exec claude --session-id <new>.
# Used on the "user declined resume" path and the "resume failed" fallback
# so cs's recorded UUID always tracks the conversation claude is about to
# create — never orphaned. The CS_FRESH_REBIND signal lets session-start.sh
# tailor its additionalContext (the user is starting fresh, not cold-booting).
_exec_fresh_rebind() {
    local session_dir="$1"
    local reason="${2:-declined-resume}"
    local handoff="${3:-}"
    local session_name
    session_name=$(basename "$session_dir")
    local old_uuid
    old_uuid=$(_read_local_state "$session_dir/.cs/local/state" claude_session_id)
    local new_uuid
    new_uuid=$(_alloc_uuid)
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$new_uuid"
    _timeline_rotated "$session_dir" "$old_uuid" "$new_uuid" "$reason" "$handoff"
    local session_color
    session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)
    local color_arg=""
    [ -n "$session_color" ] && color_arg="/color $session_color"
    # A spawn kick (exported by launch_claude_code) outranks the color
    # re-apply for this launch; both ride claude's single prompt slot.
    local launch_prompt="${CS_SPAWN_KICK:-$color_arg}"
    export CS_CLAUDE_SESSION_ID="$new_uuid"
    export CS_FRESH_REBIND=1
    # shellcheck disable=SC2086
    exec $CLAUDE_CODE_BIN --name "$session_name" --session-id "$new_uuid" ${launch_prompt:+"$launch_prompt"}
}

# Normalize an arbitrary identity string to a filesystem-safe slug.
_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-*$//'
}

# Resolve the current actor as a slug. With a session_dir arg, resolve the
# pinned identity and git config from that dir (callers may run before
# CLAUDE_SESSION_META_DIR is exported). Without, use env + cwd.
# Precedence: $CS_ACTOR > <meta>/local/identity > git user.email > git user.name > "unknown"
cs_actor_slug() {
    local sdir="${1:-}"
    local meta=""
    if [ -n "$sdir" ]; then
        meta="$sdir/.cs"
    else
        meta="${CLAUDE_SESSION_META_DIR:-}"
    fi
    local raw=""
    if [ -n "${CS_ACTOR:-}" ]; then
        raw="$CS_ACTOR"
    elif [ -n "$meta" ] && [ -f "$meta/local/identity" ]; then
        IFS= read -r raw < "$meta/local/identity"
    else
        local gitdir="${sdir:-.}"
        raw=$(git -C "$gitdir" config user.email 2>/dev/null || true)
        [ -z "$raw" ] && raw=$(git -C "$gitdir" config user.name 2>/dev/null || true)
    fi
    [ -z "$raw" ] && raw="unknown"
    _slugify "$raw"
}

# Resolve a SPECIFIC session's actor slug from its own dir, bypassing $CS_ACTOR
# (which cs_actor_slug honours first and would otherwise stamp the caller's
# identity onto every 'cs -live' row). Arg: session_dir (session root).
# Falls back to git config in that dir, then 'unknown'. Always slugified.
session_actor_slug() {  # session_dir
    local session_dir="$1" raw="" id_file="$1/.cs/local/identity"
    if [ -f "$id_file" ]; then IFS= read -r raw < "$id_file" || true; fi
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.email 2>/dev/null || true)"
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.name 2>/dev/null || true)"
    [ -n "$raw" ] || raw="unknown"
    _slugify "$raw"
}

# Print the resolved actor slug; warn if the pinned local identity disagrees with git.
cmd_whoami() {
    echo "actor: $(cs_actor_slug)"
    if [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -f "$CLAUDE_SESSION_META_DIR/local/identity" ]; then
        local file_slug="" git_raw="" git_slug=""
        file_slug=$(_slugify "$(head -1 "$CLAUDE_SESSION_META_DIR/local/identity")")
        git_raw=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || true)
        git_slug=$(_slugify "$git_raw")
        if [ -n "$git_slug" ] && [ "$file_slug" != "$git_slug" ]; then
            warn "cs actor '$file_slug' differs from git identity '$git_slug' (using cs actor)"
        fi
    fi
}

# Summarize shared memory/narrative contributors from git history (recent
# activity, by author). Not presence — purely a read over git log.
cmd_who() {
    local dir="${CLAUDE_SESSION_DIR:-$PWD}"
    [ -d "$dir/.cs" ] || error "Not in a cs session (no .cs/ in $dir)"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || error "Session is not a git repo; nothing to summarize"
    echo "Contributors to shared memory/narrative (recent activity):"
    git -C "$dir" log --format='%an|%ad' --date=short -- .cs/memory 2>/dev/null \
        | awk -F'|' '
            { count[$1]++; if ($2 > last[$1]) last[$1] = $2 }
            END {
                for (a in count) printf "%6d  %s  (last %s)\n", count[a], a, last[a]
            }' \
        | sort -rn
}

# Configure conflict-free merges for the session files that multiple
# machines write independently. The Claude-Code-maintained memory index gets
# merge=ours (it is hand-maintained; two branches editing it would conflict,
# and the local copy re-accumulates entries through normal use). The
# append-only log, timeline, and per-actor narratives get merge=union (git's
# built-in driver, no per-clone config) so divergent appends keep both sides.
