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

# A conversation id goes onto claude's command line, and the README a clone or an
# adopted project brings can say anything, so only a UUID counts as one. Same
# pattern as hooks/session-start.sh's UUID_RE.
_is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# The 8 colors claude's /color slash command accepts (verified against the
# binary's own error message in claude 2.1.162). Anything else errors with
# "Invalid color X". Notably absent: teal, magenta, white, black, gray, hex.
CS_VALID_COLORS=(red blue green yellow purple orange pink cyan)

# True when $1 is one of CS_VALID_COLORS. The recorded colour becomes claude's
# first prompt (`/color <value>`), so every reader checks it here before building
# that prompt: a README frontmatter travels with a clone or an adopted project,
# and a hand-edited state file can hold anything.
_is_session_color() {
    local c
    for c in "${CS_VALID_COLORS[@]}"; do
        [ "$1" = "$c" ] && return 0
    done
    return 1
}

# Pick a random color from CS_VALID_COLORS. Used at session creation to give
# each cs session a distinct prompt-bar accent without user choice. Claude
# defaults to teal; cs randomizes so parallel sessions are visually distinct
# at a glance.
_alloc_random_color() {
    echo "${CS_VALID_COLORS[$((RANDOM % ${#CS_VALID_COLORS[@]}))]}"
}

# Machine-local session state lives in .cs/local/state as 'key: value' lines
# (claude_session_id, claude_session_color, last_resumed, and session_name for
# adopted sessions, whose name lives in a symlink no hook can see). It is gitignored
# (see create_session_gitignore) because these values legitimately differ per
# machine — recording them in the git-synced README caused merge conflicts
# whenever two machines resumed the same session.

# Read a key's value from a machine-local state file. Prints the value to
# stdout, or empty if absent or unreadable. Never errors. KEEP THE FORMAT IN
# SYNC WITH bin/cs-statusline's _read_state_key (session name ink, context-pct
# gating) and hooks/session-start.sh's local_state_set.
# Shell builtins only: an open reads this file several times, and each read
# would otherwise fork a process. The first line beginning "key:" wins; the
# value is what follows the first colon, leading whitespace dropped and every
# double quote removed. A last line without a newline still counts.
_read_local_state() {
    local state="$1" key="$2" line value
    [ -f "$state" ] || return 0
    {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key:"*)
                    value=${line#*:}
                    value=${value#"${value%%[![:space:]]*}"}
                    printf '%s\n' "${value//\"/}"
                    break
                    ;;
            esac
        done < "$state"
    } 2>/dev/null || true
}

# Write 'key: value' into a machine-local state file, replacing any existing
# line for that key. Creates .cs/local/ and the file on first write. Atomic
# and serialised against the SessionStart hook's writer (cs_local_state_set),
# idempotent. A write that fails (permissions, a full disk) ends cs with the
# file named: the launch has already told the user what it was about to
# start, and a silent miss leaves the next open resuming nothing. Only the
# last level is made: every session cs writes state for already has its .cs,
# and one removed under a running cs ends it here rather than being built
# again from its path. A .cs/local another writer made in between is the
# directory this write wanted.
_set_local_state() {
    local state="$1" key="$2" value="$3" dir
    dir=$(dirname "$state")
    [ -d "$dir" ] || mkdir "$dir" 2>/dev/null || [ -d "$dir" ] || error "could not create $dir"
    cs_local_state_set "$state" "$key" "$value" 2>/dev/null || error "could not write $state"
}

# Remove a key's line from a machine-local state file. A missing file or key is
# a no-op. Atomic and locked like _set_local_state, and loud on the same
# failures.
_unset_local_state() {
    local state="$1" key="$2"
    cs_local_state_unset "$state" "$key" 2>/dev/null || error "could not write $state"
}

# Return the path to claude's per-cwd transcript directory. Symlinks in the
# input are resolved via `pwd -P` so the encoding matches claude's own —
# macOS mktemp returns /var/folders/... which is a symlink to
# /private/var/folders/... and claude realpaths cwd before encoding.
# A session with .cs/claude-config runs Claude Code on that config dir, so its
# transcripts live in the dir's projects/. A dangling link (vault locked) still
# names that base: the shared one never holds the session's conversations.
# Otherwise CS_TRANSCRIPTS_DIR overrides the base for tests (also used by
# doctor), then Claude Code's own config dir holds them: CLAUDE_CONFIG_DIR's
# projects/, else ~/.claude/projects. A CLAUDE_CONFIG_DIR naming some
# session's .cs/claude-config was inherited from a claude running in that
# session and says nothing about this one, so the shell's own config dir,
# which the launch keeps in CLAUDE_SECURESTORAGE_CONFIG_DIR (empty for
# ~/.claude), stands in, as it does for the keybindings (_cs_keybindings_file).
_claude_project_dir() {
    local cwd="$1" config="${CLAUDE_CONFIG_DIR:-}"
    case "$config" in
        */.cs/claude-config) config="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ;;
    esac
    local resolved base="${CS_TRANSCRIPTS_DIR:-${config:-$HOME/.claude}/projects}"
    resolved=$( (cd -- "$cwd" 2>/dev/null && pwd -P) || printf '%s' "$cwd" )
    if [ -e "$cwd/.cs/claude-config" ] || [ -L "$cwd/.cs/claude-config" ]; then
        base="$cwd/.cs/claude-config/projects"
    fi
    printf '%s/%s\n' "$base" "$(_claude_encode_path "$resolved")"
}

# Discover claude's most-recently-modified transcript UUID under a project
# directory, or empty string if none. The newest transcript is what
# `claude --continue` would resume, so binding the session's recorded UUID
# to it makes `--resume <uuid>` equivalent to `--continue` on first contact.
# Takes the project dir (not cwd) so callers that already computed it via
# _claude_project_dir can avoid a second symlink resolution.
# True when a transcript shares the session's project dir without being a
# conversation of the session: an agent-team teammate's, or a headless run's.
# A teammate started with the session as its working directory
# writes a top-level transcript into the same project dir as the lead, so the
# filename cannot tell them apart — and it is routinely the newest, because the
# teammate outlives the turn that spawned it.
#
# What separates them is WHERE the teammate frame appears, not whether it does.
# A teammate's brief IS its first user turn. A lead that merely receives
# teammate reports carries the same frame mid-file, because Claude Code injects
# an inbound message as "Another Claude session sent a message:
# <teammate-message ...>" — so testing the whole file would classify every
# team-using lead as a teammate, which is exactly the population this serves.
#
# Reads the file directly rather than `head -c N | grep -q`: an early-exiting
# pipe consumer SIGPIPEs its producer, and transcripts run to megabytes. `-m1`
# also stops at the first user turn instead of scanning a whole transcript to
# prove a marker absent.
#
# A headless run is the other occupant of the project dir: an Agent SDK call
# or a `claude -p` with the session as its working directory. Claude Code stamps
# every user line with the entrypoint that produced it, and the headless ones
# seen so far all begin `sdk-` (`sdk-py`, and `sdk-cli` for `claude -p`), while a
# person's conversation reads `cli` or `claude-desktop`. Measured over 5522
# transcripts on one machine: 4670 began headless, 842 `cli`, 6 `claude-desktop`.
#
# The first line alone does not settle it: `claude --resume` on a run a script
# started makes it a person's conversation, first line unchanged. So a file is a
# headless run only when it opens with an `sdk-` entrypoint AND no later user
# line carries a different value (any string that does not start `sdk-`, the
# empty string included). An opening line with no entrypoint at all, or one
# with a value Claude Code has not invented yet, counts as a conversation
# (unless that value itself begins `sdk-`): a
# wrongly skipped conversation leaves a session resuming nothing, which is
# worse than a wrongly named one. The second read happens only for files that
# open headless; a purely headless one is read to its end. The prompt text
# shares the line with the field, but JSON escapes its quotes, so a prompt that
# quotes the pattern cannot match it.
_is_bystander_transcript() {  # transcript_file
    local first
    first=$(grep -m1 '"type":"user"' "$1" 2>/dev/null) || return 1
    case "$first" in
        # Any first prompt holding the text counts, so discovery and adopt
        # skip a person's relocated conversation whose prompt quotes it.
        # Decided; do not re-fix.
        *teammate-message*) return 0 ;;
        *'"entrypoint":"sdk-'*)
            # Any entrypoint value that does not begin `sdk-`.
            grep -m1 -E '"entrypoint":"([^s"]|"|s[^d"]|s"|sd[^k"]|sd"|sdk[^-"]|sdk")' "$1" >/dev/null 2>&1 \
                && return 1
            return 0 ;;
    esac
    return 1
}

# Bystanders are skipped rather than merely deprioritised: naming one is wrong
# for every caller — as a rebind target it would bind the session to a
# reviewer's or a script's conversation, and as a resume suggestion it would
# offer to continue one.
_discover_session_uuid_in() {
    local proj="$1"
    [ -d "$proj" ] || return 0
    # Collect first, then iterate a here-string. A `while read` fed by a pipe
    # would SIGPIPE `ls` on the early return — the same trap the direct file
    # read above avoids.
    local listing
    listing=$(ls -t "$proj"/*.jsonl 2>/dev/null) || true
    [ -n "$listing" ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! _is_bystander_transcript "$f"; then
            basename "$f" .jsonl
            return 0
        fi
    done <<< "$listing"
    return 0
}

# The conversation of a Claude Code worktree (`claude --worktree`) once it has
# exited. While it runs, its transcript sits under the worktree's own project
# dir like any other; at exit Claude Code relocates the file into the PARENT
# repo's project dir (2.1.289), beside the parent's own conversations, and the
# worktree's dir is left empty. The moved file keeps a `worktree-state` record
# naming the worktree path, which is what tells it apart from the parent's
# conversations: the newest file in that dir is whatever was last opened on
# the parent, not this worktree. A parent conversation that stepped into the
# worktree with the EnterWorktree tool gains the same record, so the record
# alone does not make a file the worktree's: its first prompt must also be
# stamped with the worktree as cwd, which is where a `claude --worktree`
# session starts and where a parent conversation never does. Newest-first, the
# first non-bystander file that passes both is the worktree's conversation.
# Empty when none does.
_discover_worktree_uuid_in() {  # parent_project_dir, wt_dir
    local proj="$1" wt_json
    [ -d "$proj" ] || return 0
    wt_json=$(_worktree_json_path "$2")
    local listing
    listing=$(ls -t "$proj"/*.jsonl 2>/dev/null) || true
    [ -n "$listing" ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if _is_worktree_own_transcript "$f" "$wt_json"; then
            basename "$f" .jsonl
            return 0
        fi
    done <<< "$listing"
    return 0
}

# A worktree's real path as it appears inside a transcript's JSON strings: the
# record escapes a `\` or `"` in the path, so a match escapes the same way, or
# such a repo never matches. Physical, by measurement: launched from /tmp (a
# link to /private/tmp), `claude --worktree` 2.1.296 recorded worktreePath and
# cwd under /private/tmp, so pwd -P is the matching side (#814).
_worktree_json_path() {  # wt_dir
    local wt_real
    wt_real=$( (cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1" )
    printf '%s' "$wt_real" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Whether a transcript in the parent's project dir is a conversation that
# began in the worktree: it carries the worktree's record, and its first
# prompt is stamped with the worktree as cwd. This is the identity a bound
# conversation is kept by (_relocated_worktree_transcript).
_is_worktree_started_transcript() {  # transcript_file, wt_json_path
    local first
    # The closing quote pins the whole path: a worktree named `wt` must not
    # claim `wt2`'s conversation.
    grep -m1 -F "\"worktreePath\":\"$2\"" "$1" >/dev/null 2>&1 || return 1
    first=$(grep -m1 '"type":"user"' "$1" 2>/dev/null) || return 1
    case "$first" in
        *"\"cwd\":\"$2\""*) ;;
        *) return 1 ;;
    esac
}

# Whether a transcript in the parent's project dir is the worktree's own
# conversation, by the checks _discover_worktree_uuid_in describes: it began
# in the worktree, and it is no bystander.
_is_worktree_own_transcript() {  # transcript_file, wt_json_path
    _is_worktree_started_transcript "$1" "$2" && ! _is_bystander_transcript "$1"
}

# The first prompt somebody typed into a conversation, as an Objective line:
# whitespace collapsed, clipped to 100 characters with an ellipsis. Prints
# nothing when the transcript holds no such prompt, or without jq. User records
# also carry tool results, injected meta text and slash commands, which Claude
# Code records as a <command-name> block indented across lines, so a record
# counts only when its text, once collapsed, starts with none of `/`, `!` or
# `<` and runs to 8 characters or more.
# KEEP IN SYNC with the objective capture in hooks/scope-prompt.sh: the hook
# applies the same rules to the prompt it is handed live.
_transcript_first_prompt() {  # transcript_file
    local file="$1"
    [ -f "$file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # Read whole with --rawfile, not line by line with -R: jq 1.7.1's -R
    # splits a multibyte character 4095 bytes into a line, and a prompt sent
    # with an image starts past the image's base64 in its line. The read stops
    # at 16 MiB, which holds two images at the API's 5 MB limit (about 6.7 MB
    # each as base64) and the records before them, and keeps jq near 66 MiB
    # (measured: about four times the bytes read). A line the cap cuts no
    # longer parses and is skipped like any torn line.
    local candidates
    candidates=$(head -c 16777216 "$file" | jq -rn --rawfile t /dev/stdin '
        $t | split("\n")[]
        | fromjson? | select(.type == "user" and ((.isMeta // false) | not))
        | .message.content
        | if type == "string" then .
          elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" "))
          else empty end
        | gsub("[\\n\\r\\t]+"; " ") | gsub(" +"; " ")
        | select(length > 0)' 2>/dev/null) || return 0
    local line
    while IFS= read -r line; do
        line="${line# }"; line="${line% }"
        case "$line" in /*|!*|'<'*) continue ;; esac
        [ "${#line}" -ge 8 ] || continue
        [ "${#line}" -gt 100 ] && line="${line:0:100}…"
        printf '%s\n' "$line"
        return 0
    done <<< "$candidates"
    return 0
}

# Replace the Objective placeholder (a whole line wrapped in [...] under
# `## Objective`) with text, leaving every other line alone. A hand-written
# objective has no placeholder and is never touched. The README is replaced
# whole and keeps its mode; ENVIRON sidesteps awk -v escape processing of
# arbitrary prompt text. A README that cannot be rewritten keeps its
# placeholder.
_seed_readme_objective() {  # readme, text
    local readme="$1" text="$2"
    [ -f "$readme" ] && [ -n "$text" ] || return 0
    OBJ="$text" cs_write_atomic "$readme" awk '
            /^## / { in_obj = ($0 ~ /^## Objective/) }
            in_obj && /^\[.*\]$/ { print ENVIRON["OBJ"]; next }
            { print }
        ' "$readme" || return 0
}

# Terminate a JSONL file whose last line lost its newline to an interrupted
# write, so the next `>>` starts a fresh line instead of splicing two records
# onto one. The tolerant per-line reader (`fromjson? // empty` in
# run_conversations) drops a spliced line whole, which loses the torn record AND
# the intact one appended after it. The torn record itself is unrecoverable —
# it was never complete — but the next one no longer dies with it. A no-op on a
# file that is empty or already terminated, and best-effort on write like every
# other timeline append: a launch must not die because a journal could not be
# repaired. Silent even about a link out of the session: the append that
# follows names it.
_terminate_jsonl() {  # file
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
    { CS_WRITE_QUIET=1 cs_append_inside "$1" printf '\n'; } 2>/dev/null || true
}

# Append one record, built by jq -nc from the arguments, to a session's JSONL
# journal (the timeline, the queue's notifications). Best-effort like every
# journal write, so a failure never stops the verb; a link that takes the
# journal out of the session is still named on stderr, and nothing is written.
_append_record() {  # file, jq args...
    local file="$1"; shift
    _terminate_jsonl "$file"
    CS_WRITE_QUIET=1 cs_append_inside "$file" jq -nc "$@" || true
}

# Append a rotated event to the tracked timeline: the durable link between
# the conversation being left and the one about to start. Shape shared with
# hooks/session-start.sh's rebind emitter (hooks cannot source bin/cs).
# Best-effort — a timeline failure must never break a launch.
_timeline_rotated() {  # session_dir, from, to, reason, [handoff]
    local session_dir="$1" from="$2" to="$3" reason="$4" handoff="${5:-}"
    _append_record "$session_dir/.cs/timeline.jsonl" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg from "$from" \
           --arg to "$to" \
           --arg reason "$reason" \
           --arg handoff "$handoff" \
           '{ts: $ts, event: "rotated", from: $from, to: $to, reason: $reason}
            + (if $handoff == "" then {} else {handoff: $handoff} end)'
}

# Allocate a fresh UUID, rewrite the local state's claude_session_id to it, export
# CS_CLAUDE_SESSION_ID + CS_FRESH_REBIND, and exec claude --session-id <new>.
# Used on the "user declined resume" path and the "resume failed" fallback
# so cs's recorded UUID always tracks the conversation claude is about to
# create — never orphaned. The CS_FRESH_REBIND signal lets session-start.sh
# tailor its additionalContext (the user is starting fresh, not cold-booting).
# With no recorded conversation to leave (the first open after cs -adopt, a
# clone without its machine-local state) this is the session's first
# conversation, not a rotation: no timeline event, no CS_FRESH_REBIND.
_exec_fresh_rebind() {
    local session_dir="$1"
    local reason="${2:-declined-resume}"
    local handoff="${3:-}"
    local spawn_kick="${4:-}"
    local merge_kick="${5:-}"
    # An adopted session's name is the link's, recorded in local state at the
    # open; its directory is the project's. Every other session is its
    # directory.
    local session_name
    session_name=$(_read_local_state "$session_dir/.cs/local/state" session_name)
    [ -n "$session_name" ] || session_name=$(basename "$session_dir")
    # Only a UUID names a conversation to leave; the launch ignores anything
    # else in the slot, and so does the rotation record.
    local old_uuid
    old_uuid=$(_read_local_state "$session_dir/.cs/local/state" claude_session_id)
    _is_uuid "$old_uuid" || old_uuid=""
    local new_uuid
    new_uuid=$(_alloc_uuid)
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$new_uuid"
    # An encrypted session's handoff name is its topic, so it stays out of
    # the plaintext timeline and out of claude's argv (visible to ps and in a
    # terminal title); the SessionStart hook names the file from the vault.
    local public_handoff="$handoff"
    if [ -L "$session_dir/.cs/private" ] || [ -e "$session_dir/.cs/private" ]; then
        public_handoff=""
    fi
    [ -z "$old_uuid" ] || _timeline_rotated "$session_dir" "$old_uuid" "$new_uuid" "$reason" "$public_handoff"
    local session_color
    session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)
    local color_arg=""
    _is_session_color "$session_color" && color_arg="/color $session_color"
    # A handoff kick makes the fresh conversation act on its first turn instead of
    # waiting for the user. It stays a bare trigger on purpose: the SessionStart
    # hook (which the same r answer arms via the pending-handoff marker) is the
    # single owner of the how — next-step section, transcript-not-loaded, the
    # narrative pointers — so the wording lives in one place. A merge kick
    # outranks a spawn kick, which outranks the handoff, which outranks the
    # color re-apply; all four ride claude's single prompt slot, so a displaced
    # color returns on the next open.
    local handoff_arg=""
    if [ -n "$public_handoff" ]; then
        handoff_arg="Continue from the pending rotation handoff: read .cs/handoffs/$handoff first."
    elif [ -n "$handoff" ]; then
        handoff_arg="Continue from the pending rotation handoff."
    fi
    local launch_prompt="${merge_kick:-${spawn_kick:-${handoff_arg:-$color_arg}}}"
    export CS_CLAUDE_SESSION_ID="$new_uuid"
    [ -z "$old_uuid" ] || export CS_FRESH_REBIND=1
    # shellcheck disable=SC2086
    exec $CLAUDE_CODE_BIN --name "$(cs_claude_name "$session_name")" --session-id "$new_uuid" ${launch_prompt:+"$launch_prompt"}
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
# append-only log, timeline, per-actor narratives and the memory archive (the
# pointers /wrap moves out of the index) get merge=union (git's built-in
# driver, no per-clone config) so divergent appends keep both sides.
