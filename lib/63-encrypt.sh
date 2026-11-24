# ABOUTME: cs -encrypt: moves an existing, closed session's private files into an
# ABOUTME: encrypted sparsebundle (diskutil image) and links the four vault names into its mount.

# Where the container lives: outside every session directory, so neither
# cs -rm nor the autosave snapshot ever reaches it.
_encrypt_container_path() {  # session_name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# Every precondition, checked before anything is written.
_encrypt_refuse() {  # session_name
    local name="$1" dir meta sub container
    [ "$(uname -s)" = "Darwin" ] || error "cs -encrypt needs macOS (diskutil); Linux is not supported yet."
    case "$name" in
        *@*) error "$name: encrypt the base session, not a feature worktree." ;;
    esac
    validate_session_name "$name"
    dir="$SESSIONS_ROOT/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || error "No such session: $name"
    [ -L "$dir" ] && error "$name: an adopted session cannot be encrypted; its .cs/ lives in the project checkout."
    cs_interactive || error "cs -encrypt asks for the vault password; run it from a terminal."
    meta="$dir/.cs"
    session_is_live "$meta" && error "$name: the session is live; close it, then encrypt."
    for sub in $CS_VAULT_LINKS; do
        [ -L "$meta/$sub" ] && error "$name: .cs/$sub is already a link; the session is encrypted, or half set up by hand."
    done
    # memory and plans move into the vault; these two are only linked, so a
    # real one would take the link inside it and keep its files in plaintext.
    for sub in claude-config private; do
        [ -e "$meta/$sub" ] && error "$name: .cs/$sub already exists and is not a link; cs -encrypt links it into the vault. Move it aside first."
    done
    [ -e "$meta/local/pre-open" ] && error "$name: .cs/local/pre-open already exists; cs -encrypt writes its own. Move yours aside first."
    container=$(_encrypt_container_path "$name")
    [ -e "$container" ] && error "$name: $container already exists; cs -encrypt will not reuse or overwrite it."
    if ! _tags_has_frontmatter "$meta/README.md" || _tags_has_block_style "$meta/README.md"; then
        error "$name: .cs/README.md has no YAML frontmatter to carry the encrypted tag."
    fi
    return 0
}

# Each "source destination" pair to move, source relative to .cs/, destination
# relative to the mount. Only sources that exist are listed.
_encrypt_moves() {  # meta_dir
    local meta="$1" f
    [ -e "$meta/memory" ] && echo "memory memory"
    [ -e "$meta/plans" ] && echo "plans plans"
    for f in $CS_PRIVATE_LOCAL_FILES; do
        [ -e "$meta/local/$f" ] && echo "local/$f private/$f"
    done
    for f in handoffs checkpoints narrative-archive; do
        [ -e "$meta/$f" ] && echo "$f private/$f"
    done
    return 0
}

# Moves one name at a time. A failure stops and names what moved and what did
# not: a rollback would be more moves that can fail the same way.
_encrypt_move_content() {  # session_name, meta_dir
    local name="$1" meta="$2" mnt="$2/vault-mnt" moves src dst moved="" rest
    moves=$(_encrypt_moves "$meta")
    mkdir -p "$mnt/private" "$mnt/claude-config"
    while read -r src dst; do
        [ -n "$src" ] || continue
        if ! mv "$meta/$src" "$mnt/$dst" 2>/dev/null; then
            rest=$(printf '%s\n' "$moves" | awk -v s="$src" 'found || $1 == s { found = 1; printf " .cs/%s", $1 }')
            error "$name: could not move .cs/$src into the vault. Already moved:${moved:- nothing}. Not moved:$rest. The vault is still mounted at .cs/vault-mnt; finish by hand or move those back, then detach it."
        fi
        moved="$moved .cs/$src"
    done <<< "$moves"
    mkdir -p "$mnt/memory" "$mnt/plans"
}

# The hook cs runs before every open: attaches the vault, asking for its
# password each time. A mount whose session is not running is a leftover (a
# crash, or a detach that failed), so it is detached and asked for again.
# Whether the session is running comes from cs in CS_LIVE_LOCK_PID
# (_run_pre_open); the hook never reads the lock, and without the variable,
# or with one that names no running process, it counts the mount as held by
# no running session. Its pid check takes only a number without leading
# zeros, as cs writes them: kill -0 reads 0 as the caller's process group,
# which is always there, and the leftover loop would signal that group.
# Reads one line from the terminal without showing it, into CS_SECRET_REPLY.
# read -s turns the terminal's echo off, and bash 3.2 leaves it off when
# Ctrl-C ends the read, so the terminal's settings are put back first; the
# exit runs cs's EXIT trap.
_encrypt_read_secret() {  # prompt
    CS_SECRET_SAVED_TTY=""
    CS_SECRET_REPLY=""
    [ -t 0 ] && CS_SECRET_SAVED_TTY=$(stty -g 2>/dev/null) || true
    trap '[ -z "$CS_SECRET_SAVED_TTY" ] || stty "$CS_SECRET_SAVED_TTY" 2>/dev/null; echo >&2; exit 130' INT
    printf '%s' "$1" >&2
    IFS= read -rs CS_SECRET_REPLY || true
    trap - INT
    echo >&2
}

# What cs draws where it asks for a vault password: the session as the status
# line shows it, then what the vault is, and under it the row that takes the
# typing. The lock glyph shows only with Nerd Fonts: the plain one is missing
# from common terminal fonts.
_vault_prompt_head() {  # session_name, session_dir, what the vault is
    local color="" lock=""
    color=$(_read_local_state "$2/.cs/local/state" claude_session_color 2>/dev/null) || color=""
    [ "${CS_NERD_FONTS:-}" = "1" ] && lock="$ICON_LOCK "
    printf '%s  %b%s%s%b' "$(_session_pill "$1" "$color")" "$YELLOW" "$lock" "$3" "$NC"
}

_vault_prompt_ask() {  # label
    printf '    %b%s%b %b›%b ' "$DIM" "$1" "$NC" "$GOLD" "$NC"
}

# cs asks for the password itself and hands it to diskutil on stdin: left to
# ask, diskutil shows a dialog that offers to save the password in the
# keychain. Only diskutil's errors are shown; its device table is not.
CS_PRE_OPEN_MARK='# Written by cs -encrypt: mounts this session vault, asking for its password at every open.'

_encrypt_pre_open_text() {  # container
    echo '#!/bin/bash'
    echo "$CS_PRE_OPEN_MARK"
    echo 'set -euo pipefail'
    printf 'container=%q\n' "$1"
    cat <<'EOF'
mkdir -p .cs/vault-mnt
mnt=$(cd .cs/vault-mnt && pwd -P)
mounted() { mount | grep -F " on $mnt (" >/dev/null; }
alive() { case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac; kill -0 "$1" 2>/dev/null; }
lock_alive() { alive "${CS_LIVE_LOCK_PID:-}"; }
holder_alive() {
    local pid
    [ -f .cs/local/vault-holders ] || return 1
    while read -r pid; do
        alive "$pid" && return 0
    done < .cs/local/vault-holders
    return 1
}
if mounted; then
    { lock_alive || holder_alive; } && exit 0
    # A leftover from a conversation that ended. Stop its waiter, and the
    # detach the waiter may have started, before touching the volume.
    for f in vault-waiter.pid vault-detach.pid; do
        pid=$(cat ".cs/local/$f" 2>/dev/null || true)
        alive "$pid" || continue
        kill "$pid" 2>/dev/null || true
        i=0
        while alive "$pid" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    done
    rm -f .cs/local/vault-waiter.pid .cs/local/vault-detach.pid .cs/local/vault-holders
    if mounted && ! diskutil eject "$mnt" >/dev/null; then
        echo "cs: the vault is still mounted from a conversation that ended, and it would not detach. Close whatever holds it, run: diskutil eject $mnt" >&2
        exit 1
    fi
fi
if ! { [ -t 0 ] || [ "${CS_ASSUME_TTY:-}" = "1" ]; }; then
    echo "cs: this session is encrypted and needs a terminal to ask for the vault password." >&2
    exit 1
fi
# read -s turns the terminal's echo off, and bash 3.2 leaves it off when
# Ctrl-C ends the read, so the terminal's settings are put back first.
saved=""
[ -t 0 ] && saved=$(stty -g 2>/dev/null) || true
trap '[ -z "$saved" ] || stty "$saved" 2>/dev/null; echo >&2; exit 130' INT
# cs passes the rows to draw; run by hand, the hook asks in plain words.
[ -z "${CS_VAULT_PROMPT_HEAD:-}" ] || printf '%s\n' "$CS_VAULT_PROMPT_HEAD" >&2
ask=${CS_VAULT_PROMPT_ASK:-"Vault password for ${PWD##*/}: "}
wrong=${CS_VAULT_PROMPT_WRONG:-"cs: wrong password."}
tries=0
while :; do
    printf '%s' "$ask" >&2
    password=""
    IFS= read -rs password || true
    echo >&2
    if [ -z "$password" ]; then
        echo "cs: no vault password entered." >&2
        exit 1
    fi
    out=$(printf '%s' "$password" | diskutil image attach --stdinpassphrase --nobrowse --mountPoint "$mnt" "$container" 2>&1) && break
    case "$out" in
        *"Incorrect passphrase"*) ;;
        *) echo "cs: the vault did not open. diskutil said: $out" >&2; exit 1 ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
        echo "cs: three wrong passwords; the vault stays locked." >&2
        exit 1
    fi
    printf '%s\n' "$wrong" >&2
done
trap - INT
EOF
}

_encrypt_write_pre_open() {  # meta_dir, container
    local hook="$1/local/pre-open"
    _encrypt_pre_open_text "$2" > "$hook"
    chmod +x "$hook"
}

# The open runs the pre-open this cs writes, so a vault another version of cs
# built opens the same way. Only a hook cs wrote is replaced, by its second
# line: one written by hand for a vault set up by hand stays as it is.
_encrypt_refresh_pre_open() {  # meta_dir
    local hook="$1/local/pre-open" container text
    [ -f "$1/local/vault" ] || return 0
    [ "$(sed -n 2p "$hook" 2>/dev/null)" = "$CS_PRE_OPEN_MARK" ] || return 0
    container=$(cat "$1/local/vault")
    [ -n "$container" ] || return 0
    text=$(_encrypt_pre_open_text "$container")
    [ "$text" = "$(cat "$hook")" ] && return 0
    # Where diskutil has no image verbs, the hook cs wrote before still opens
    # the vault and this one would not, so that one stays.
    diskutil image --help >/dev/null 2>&1 || return 0
    # Made new, never written through: a link planted at the temporary name
    # would carry the hook's text to wherever it points.
    rm -f "$hook.$$" 2>/dev/null || true
    ( set -C; printf '%s\n' "$text" > "$hook.$$" ) 2>/dev/null \
        || error "${1%/.cs}: could not write .cs/local/pre-open.$$ to replace the pre-open cs wrote."
    chmod +x "$hook.$$"
    mv -f "$hook.$$" "$hook"
}

# .cs/local/vault-holders lists the pids whose life keeps the vault mounted:
# every cs run whose pre-open attached or joined it. exec keeps the pid, so a
# claude that replaced its cs stays a holder; a cs that ends without exec
# (a refusal, a cancelled prompt, or claude run as its child) leaves, and
# detaches the vault if it was the last live holder.
CS_OPENED_VAULT_META=""

_vault_live_holder_besides() {  # meta_dir, pid -> true if another listed holder is alive
    local pid
    [ -f "$1/local/vault-holders" ] || return 1
    while read -r pid; do
        [ "$pid" = "$2" ] && continue
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null && return 0
    done < "$1/local/vault-holders"
    return 1
}

_vault_mountpoint_if_mounted() {  # meta_dir -> prints the mountpoint, or fails
    local mnt
    mnt=$(cd -- "$1/vault-mnt" 2>/dev/null && pwd -P) || return 1
    mount | grep -F " on $mnt (" >/dev/null || return 1
    printf '%s\n' "$mnt"
}

_arm_vault_detach() {  # session_dir
    local meta="$1/.cs"
    [ -f "$meta/local/vault" ] || return 0
    _vault_mountpoint_if_mounted "$meta" >/dev/null || return 0
    cs_vault_holder_add "$meta/local/vault-holders" "$$"
    CS_OPENED_VAULT_META="$meta"
    trap _detach_opened_vault EXIT
}

# A cs that execs something other than claude stops holding the vault: its
# pid lives on in a process that never opens it. Other lines stay as they are.
_vault_leave() {
    local meta="$CS_OPENED_VAULT_META"
    [ -n "$meta" ] || return 0
    CS_OPENED_VAULT_META=""
    cs_vault_holder_drop "$meta/local/vault-holders" "$$"
}

# The holder list is read, never rewritten, here: dead pids and this one are
# skipped, so a concurrent open's line is never lost.
_detach_opened_vault() {
    local meta="$CS_OPENED_VAULT_META" mnt lock
    [ -n "$meta" ] || return 0
    _vault_live_holder_besides "$meta" "$$" && return 0
    lock=$(live_lock_pid "$meta")
    [ -n "$lock" ] && [ "$lock" != "$$" ] && return 0
    mnt=$(_vault_mountpoint_if_mounted "$meta") || return 0
    diskutil eject "$mnt" >/dev/null 2>&1 && return 0
    _vault_mountpoint_if_mounted "$meta" >/dev/null || return 0
    warn "The vault is still mounted at $mnt; the next open detaches it, or run: diskutil eject $mnt"
}

# Claude Code's config dir as the shell has it, outside any vault, read as
# _claude_project_dir reads it: a session's conversations sit under it until
# cs -encrypt, or the first open after, moves them into the vault.
_plain_claude_config_dir() {
    local config="${CLAUDE_CONFIG_DIR:-}"
    case "$config" in
        */.cs/claude-config) config="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ;;
    esac
    printf '%s\n' "${config:-$HOME/.claude}"
}

_plain_claude_project_dir() {  # session_dir
    local resolved
    resolved=$( (cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1" )
    printf '%s/%s\n' "${CS_TRANSCRIPTS_DIR:-$(_plain_claude_config_dir)/projects}" "$(_claude_encode_path "$resolved")"
}

# An empty folder holds nothing to move: Claude Code makes an empty memory/ in
# every project folder, so the one outside and the one in the vault are no
# clash, and the one outside is removed. One in the vault makes way for a
# folder of the same name from outside.
_empty_real_dir() {  # path
    [ -d "$1" ] && [ ! -L "$1" ] && [ -z "$(ls -A -- "$1" 2>/dev/null)" ]
}

# True when the vault's path holds all that the one outside holds: two links
# to one target, two files byte for byte, or a folder whose every entry the
# vault's folder holds so. The vault's folder may hold more: a removal
# outside that stopped inside a folder leaves a part of it there. A folder
# outside that cs cannot list or enter holds entries nobody compared, so the
# vault is not said to hold it.
_vault_holds_all_of() {  # path outside, path in the vault
    local entry
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    elif [ -d "$1" ] && [ -d "$2" ]; then
        [ -r "$1" ] && [ -x "$1" ] || return 1
        for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            _vault_holds_all_of "$entry" "$2/${entry##*/}" || return 1
        done
        return 0
    elif [ -f "$1" ] && [ -f "$2" ]; then
        cmp -s "$1" "$2"
    else
        return 1
    fi
}

# Ends a copy into the vault that stopped: removes the staging folder this
# run made and leaves what the tool said in CS_MOVE_ERROR.
_conversations_copy_stopped() {  # staging_dir, what the tool said
    local out
    CS_MOVE_ERROR=$2
    out=$(rm -rf "$1" 2>&1) || CS_MOVE_ERROR="$2; removing $1 failed too: $out"
}

# Moves the entries of a session's conversations folder into the vault's.
# The copy into the vault can stop part-way, on a full disk, so it lands in a
# staging folder beside the vault's projects folder: an entry is renamed into
# the session's folder only once all of them are copied, and what is outside
# is removed only once all of them are in place. An entry whose name the
# vault already holds is not copied: the caller checked that the vault's is
# an empty folder, which makes way, or holds all of the entry, so the one
# outside only goes.
# Returns 0 with nothing left outside; 1 with everything outside as it was;
# 2 with whole copies in the vault and something outside that would not go.
# CS_MOVED_ENTRIES names what reached the session's folder in the vault,
# CS_REMOVED_COPIES what the vault held already and went from outside, each
# named once it is gone, and CS_MOVE_ERROR holds what the tool that stopped
# said.
_move_conversations_into_vault() {  # plain_dir, vault_dir
    local staging="${2%/*}.cs-moving.$$" entry name out i
    local -a outside=() copied=() held=()
    CS_MOVE_ERROR=""
    CS_MOVED_ENTRIES=""
    CS_REMOVED_COPIES=""
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=${entry##*/}
        outside+=("$name")
        held+=("")
        _empty_real_dir "$entry" && continue
        if [ -e "$2/$name" ] || [ -L "$2/$name" ]; then
            _empty_real_dir "$2/$name" || { held[${#held[@]}-1]=1; continue; }
        fi
        copied+=("$name")
    done
    if [ "${#copied[@]}" -gt 0 ]; then
        out=$(mkdir -p "${2%/*}" 2>&1 && mkdir "$staging" 2>&1) || { CS_MOVE_ERROR=$out; return 1; }
        for name in "${copied[@]}"; do
            out=$(cp -pPR "$1/$name" "$staging/" 2>&1) \
                || { _conversations_copy_stopped "$staging" "$out"; return 1; }
        done
        out=$(mkdir -p "$2" 2>&1) || { _conversations_copy_stopped "$staging" "$out"; return 1; }
        for name in "${copied[@]}"; do
            out=$( { [ ! -d "$2/$name" ] || rmdir "$2/$name"; } 2>&1 && mv "$staging/$name" "$2/$name" 2>&1) \
                || { _conversations_copy_stopped "$staging" "$out"; return 1; }
            CS_MOVED_ENTRIES="$CS_MOVED_ENTRIES $name"
        done
        out=$(rmdir "$staging" 2>&1) || { CS_MOVE_ERROR=$out; return 1; }
    fi
    if [ "${#outside[@]}" -gt 0 ]; then
        for i in "${!outside[@]}"; do
            name=${outside[$i]}
            if _empty_real_dir "$1/$name"; then
                out=$(rmdir "$1/$name" 2>&1) || { CS_MOVE_ERROR=$out; return 2; }
            else
                out=$(rm -rf -- "${1:?}/$name" 2>&1) || { CS_MOVE_ERROR=$out; return 2; }
            fi
            [ -z "${held[$i]}" ] || CS_REMOVED_COPIES="$CS_REMOVED_COPIES $name"
        done
    fi
    out=$(rmdir "$1" 2>&1) || { CS_MOVE_ERROR=$out; return 2; }
}

# What the vault holds of the conversations after a copy that stopped.
_conversations_in_vault_after_a_stop() {
    if [ -n "$CS_MOVED_ENTRIES" ]; then
        printf 'whole copies of%s and none of the rest' "$CS_MOVED_ENTRIES"
    else
        printf 'none of them'
    fi
}

# What a move that could not remove everything outside the vault tells the
# user: the vault's copies are whole, and what is left is in plain text.
_warn_conversations_left_outside() {  # session_name, plain_dir
    warn "$1: the vault holds whole copies of this session's conversations, but cs could not remove them all from outside it. What is left in $2 is in plain text; remove it by hand. Removing it failed with: $CS_MOVE_ERROR"
}

# Reads the sessionId, procStart and cwd of a sessions file, a line each,
# into CS_CLAUDE_PROCESS_FIELDS. Returns 1 when the file holds no JSON value
# or one jq cannot read, with why in CS_MOVE_ERROR.
_read_claude_process_file() {  # file
    if ! CS_CLAUDE_PROCESS_FIELDS=$(jq -r '
            (.sessionId | if type == "string" and test("^[A-Za-z0-9_-]+$") then . else "-" end),
            (.procStart | if type == "string" then gsub("[\n\r]"; " ") else "" end),
            (.cwd | if type == "string" then gsub("[\n\r]"; " ") else "" end)' "$1" 2>&1); then
        CS_MOVE_ERROR="jq said: $CS_CLAUDE_PROCESS_FIELDS"
        return 1
    fi
    [ -n "$CS_CLAUDE_PROCESS_FIELDS" ] && return 0
    CS_MOVE_ERROR="The file holds no JSON value."
    return 1
}

# True when a sessions file was last written more than two seconds before
# the process its pid names started, the margin Claude Code's own reader
# takes: the file is then of an earlier process with that pid, which left
# it. A file that is gone, or a process that ended since, holds nothing back
# either. ps gives the time the process has run as [[dd-]hh:]mm:ss; when it
# gives none for a process still there, the file is not called older.
_older_than_process() {  # file, pid
    local ran now
    [ -f "$1" ] || return 0
    ran=$("${CS_PS_BIN:-ps}" -o etime= -p "$2" 2>/dev/null | awk '{
        n = split($1, t, /[-:]/); split("1 60 3600 86400", unit, " ")
        for (i = n; i >= 1; i--) s += t[i] * unit[n - i + 1]
        print s }') || ran=""
    if [ -z "$ran" ]; then
        ! kill -0 "$2" 2>/dev/null
        return
    fi
    now=$(date +%s)
    [ $(( now - $(_epoch_mtime "$1") )) -gt $(( ran + 2 )) ]
}

# Finds a claude Claude Code lists as running in the session (sessions/
# <pid>.json in its config dir), writing its conversations outside the vault,
# and leaves its pid in CS_PLAIN_WRITER. jq reads the file, so a path with a
# quote or a backslash in it is the path and not its escape.
# The file's cwd is the folder the claude started in: a cd leaves it as it
# is, and only entering or leaving a worktree rewrites it. A claude that
# resumed a conversation keeps writing it in that conversation's folder, so
# one resumed in the session that then entered a worktree has its cwd
# elsewhere. The file's sessionId counts as well: a conversation of that
# name in the session's folder, or its folder of subagents, is one the
# claude writes.
# The file outlives a claude that was killed, and its pid can come to name
# another process: Claude Code records the start time beside it, procStart,
# as `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` prints it, so a file whose
# start time is not the process's is skipped. Without a recorded start time,
# or an answer from ps, the pid being alive is enough.
# Claude Code writes the file in place, so a read can find it empty or cut
# short: cs reads it again after a pause, as Claude Code's own reader does.
# A file still unreadable then is skipped when it is a leftover, older than
# the process its pid names.
# Returns 1 when no such claude runs, and 2 when the file of a running
# process cannot be read, with that file in CS_PLAIN_WRITER_FILE and why in
# CS_MOVE_ERROR: a claude nobody can rule out.
_plain_claude_writer() {  # session_dir, plain_dir
    local f pid sid recorded cwd started
    CS_PLAIN_WRITER=""
    CS_PLAIN_WRITER_FILE=""
    for f in "$(_plain_claude_config_dir)"/sessions/*.json; do
        [ -f "$f" ] || continue
        pid=${f##*/}
        pid=${pid%.json}
        case "$pid" in ''|0*|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null || continue
        CS_PLAIN_WRITER=$pid
        if ! _read_claude_process_file "$f"; then
            sleep 0.05
            if ! _read_claude_process_file "$f"; then
                _older_than_process "$f" "$pid" && continue
                CS_PLAIN_WRITER_FILE=$f
                return 2
            fi
        fi
        { IFS= read -r sid; IFS= read -r recorded; IFS= read -r cwd; } <<< "$CS_CLAUDE_PROCESS_FIELDS" || true
        if [ -n "$recorded" ]; then
            started=$(LC_ALL=C TZ=UTC "${CS_PS_BIN:-ps}" -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//') || started=""
            [ -z "$started" ] || [ "$started" = "$recorded" ] || continue
        fi
        [ "$cwd" = "$1" ] || [ "$cwd" -ef "$1" ] \
            || [ -e "$2/$sid.jsonl" ] || [ -d "$2/$sid" ] || continue
        return 0
    done
    CS_PLAIN_WRITER=""
    return 1
}

# Why a session's conversations must stay outside the vault for now, in
# CS_MOVE_REFUSAL, ending with what the caller says of a running claude.
# Returns 1 when nothing stands in the way.
_conversations_move_refusal() {  # session_dir, plain_dir, what to do about a running claude
    local rc=0
    CS_MOVE_REFUSAL=""
    _plain_claude_writer "$1" "$2" || rc=$?
    case "$rc" in
        0) CS_MOVE_REFUSAL="a claude (pid $CS_PLAIN_WRITER) runs in this session outside cs and writes its conversations to $2, so cs moved none of them into the vault. $3" ;;
        1) return 1 ;;
        2) CS_MOVE_REFUSAL="cs could not read $CS_PLAIN_WRITER_FILE, which Claude Code keeps for a running process (pid $CS_PLAIN_WRITER), so it cannot tell whether a claude writes the conversations in $2, and moved none of them into the vault. The next open moves them once that process has ended. $CS_MOVE_ERROR" ;;
        *) error "_plain_claude_writer returned $rc for $1" ;;
    esac
    return 0
}

# A folder cs cannot list reads as an empty one, with nothing in it to copy
# and nothing the vault lacks, and one it can list but not enter cannot be
# copied or compared. So nothing moves while the conversations folder outside
# the vault, or the session's folder in it, holds a folder cs cannot both
# list and enter, or one find cannot walk. find passes a folder it cannot
# enter without a word, and words its errors by platform, so test asks of
# each folder and cs names the first in its own words; find's first line
# ends CS_MOVE_REFUSAL's sentence only when no folder failed that test.
# Returns 1 when it walked both and every folder passed.
_unreadable_conversations_refusal() {  # plain_dir, vault_dir
    local dir said folder why nl=$'\n'
    local -a not_open=(-type d \( ! -exec test -r {} \; -o ! -exec test -x {} \; \) -print)
    CS_MOVE_REFUSAL=""
    for dir in "$1" "$2"; do
        [ -d "$dir" ] || continue
        said=$(find "$dir" "${not_open[@]}" 2>&1) && [ -z "$said" ] && continue
        folder=$(find "$dir" "${not_open[@]}" 2>/dev/null) || true
        folder=${folder%%"$nl"*}
        if [ -z "$folder" ]; then
            why="find said: ${said%%"$nl"*}"
            [ -n "$said" ] || why="find failed and said nothing."
        elif [ -r "$folder" ]; then
            why="cs cannot enter $folder."
        else
            why="cs cannot list $folder."
        fi
        CS_MOVE_REFUSAL="cs cannot read every folder under $dir, so it moved none of the conversations in $1 into the vault: they are all still there, and the vault holds what it held before. The next open moves them once cs can read every folder. $why"
        return 0
    done
    return 1
}

# Claude Code names a project folder after the path its claude ran in, with
# every character that is no letter or digit turned into a dash, so session
# foo-bar and a claude run in foo/bar keep their conversations in one folder.
# Each line of a conversation records that path as cwd. A conversation with
# a cwd that is not the session's, yet takes the same folder, belongs to the
# other path; the filesystem says whether two names are one folder, as it
# does for names that differ only in the case of a letter. The file and that
# path go in CS_MOVE_REFUSAL's sentence, and the folder stays, since what
# else it holds (memory/, the index) cannot be told apart by owner. A cwd under another folder name is this session's
# claude after a cd. Returns 1 when every conversation is the session's.
_foreign_conversation_refusal() {  # session_dir, plain_dir
    local f tokens cwds cwd
    CS_MOVE_REFUSAL=""
    for f in "$2"/*.jsonl; do
        [ -f "$f" ] || continue
        # Each cwd as the JSON string the line holds, once; jq then reads
        # those few, where a whole conversation would be megabytes.
        tokens=$(LC_ALL=C grep -o -E '"cwd":"([^"\\]|\\.)*"' "$f" 2>/dev/null | sort -u) || tokens=""
        [ -n "$tokens" ] || continue
        cwds=$(printf '%s\n' "$tokens" | sed 's/^"cwd"://' | jq -r '"cwd:" + gsub("[\n\r]"; " ")' 2>&1) \
            || cwds=${cwds:-jq failed and said nothing}
        while IFS= read -r cwd; do
            case "$cwd" in
                cwd:*) cwd=${cwd#cwd:} ;;
                *)
                    CS_MOVE_REFUSAL="cs could not read the folder a claude ran in from $f, so it cannot tell whose conversation that is, and moved none of the conversations in $2 into the vault. They stay outside it, in plain text. jq said: $cwd"
                    return 0
                    ;;
            esac
            [ -n "$cwd" ] && [ "$cwd" != "$1" ] && [ ! "$cwd" -ef "$1" ] || continue
            [ "${2%/*}/$(_claude_encode_path "$cwd")" -ef "$2" ] || continue
            CS_MOVE_REFUSAL="$f is a conversation claude held in $cwd, which Claude Code files under the same folder as this session, so cs moved none of the conversations in $2 into the vault. They stay outside it, in plain text."
            return 0
        done <<< "$cwds"
    done
    return 1
}

# A session cs -encrypt sealed before it moved conversations keeps them in
# the shell's projects folder, where its claude, on the vault's config, never
# looks. With the vault mounted, the open moves them in as cs -encrypt does,
# and says so; the folder is gone after, so the next open has nothing to do.
# A link, a name on both sides, a claude writing there, a folder cs cannot
# read, or a conversation of another path in the folder is named instead,
# and the open goes on with nothing moved. The move runs under the openers' mutex, so a second open
# started beside this one finds the folder gone rather than copying it again
# into the one this open just made; an open that cannot take the mutex
# stops, as its launch would.
_move_plain_conversations_at_open() {  # session_name, session_dir
    local meta="$2/.cs" plain mutex="$2/.cs/session.mutex.lock"
    [ -f "$meta/local/vault" ] && [ -L "$meta/claude-config" ] || return 0
    _vault_mountpoint_if_mounted "$meta" >/dev/null || return 0
    plain=$(_plain_claude_project_dir "$2")
    if [ -L "$plain" ]; then
        warn "$1: $plain is a link, so cs moved nothing from it; the conversations in the folder it points to stay outside the vault, in plain text."
        return 0
    fi
    [ -d "$plain" ] || return 0
    _cs_lock "$mutex" \
        || error "$1: another cs is opening this session ($mutex is held), so cs moved none of its conversations into the vault; try again in a moment."
    _move_plain_conversations_under_mutex "$1" "$2" "$plain"
    _cs_unlock "$mutex"
}

_move_plain_conversations_under_mutex() {  # session_name, session_dir, plain_dir
    local meta="$2/.cs" plain="$3" vault entry rc=0
    [ -d "$plain" ] || return 0
    if _conversations_move_refusal "$2" "$plain" "Reopen once it has ended."; then
        warn "$1: $CS_MOVE_REFUSAL"
        return 0
    fi
    vault="$meta/claude-config/projects/${plain##*/}"
    if _unreadable_conversations_refusal "$plain" "$vault"; then
        warn "$1: $CS_MOVE_REFUSAL"
        return 0
    fi
    for entry in "$plain"/* "$plain"/.[!.]* "$plain"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        _empty_real_dir "$entry" && continue
        [ -e "$vault/${entry##*/}" ] || [ -L "$vault/${entry##*/}" ] || continue
        _empty_real_dir "$vault/${entry##*/}" && continue
        _vault_holds_all_of "$entry" "$vault/${entry##*/}" && continue
        warn "$1: $entry is in the vault too, as .cs/claude-config/projects/${plain##*/}/${entry##*/}, so cs moved none of the conversations in $plain. Keep the copy you want in the vault, remove the other, then reopen."
        return 0
    done
    if _foreign_conversation_refusal "$2" "$plain"; then
        warn "$1: $CS_MOVE_REFUSAL"
        return 0
    fi
    _move_conversations_into_vault "$plain" "$vault" || rc=$?
    case "$rc" in
        0) ;;
        1) error "$1: could not copy the session's conversations from $plain into its vault. They are all still in $plain, whole, and the vault holds $(_conversations_in_vault_after_a_stop). cp said: $CS_MOVE_ERROR" ;;
        2) _warn_conversations_left_outside "$1" "$plain" ;;
        *) error "_move_conversations_into_vault returned $rc for $plain" ;;
    esac
    case "$CS_MOVED_ENTRIES " in
        " ") ;;
        *".jsonl "*) info "$1: moved this session's conversations from $plain into its vault." ;;
        *) info "$1: moved$CS_MOVED_ENTRIES from $plain into its vault." ;;
    esac
    [ -z "$CS_REMOVED_COPIES" ] || info "$1: removed from $plain what its vault already holds:$CS_REMOVED_COPIES."
}

run_encrypt() {
    [ $# -eq 1 ] || error "Usage: cs -encrypt <name>"
    local name="$1" meta container mnt sub taken=0 password="" again="" out transcripts moved move_rc=0 stayed=""
    _encrypt_refuse "$name"
    meta="$SESSIONS_ROOT/$name/.cs"
    # Hold the session lock while the password prompts run, so an open in
    # another terminal meets the collision check instead of racing the moves.
    # It is taken as an open takes it, under the openers' mutex: when an open
    # took it after the live check above, cs -encrypt refuses and leaves it.
    _take_session_lock "$meta" || taken=$?
    case "$taken" in
        0) ;;
        1) error "$name: the session is live; close it, then encrypt." ;;
        2) error "$name: another cs is opening this session ($meta/session.mutex.lock is held); try again in a moment." ;;
        *) error "_take_session_lock returned $taken for $meta" ;;
    esac
    # shellcheck disable=SC2064  # the path is fixed now, on purpose
    # printf %q quotes the path for the trap's own parse, so a space, a quote,
    # $( or a newline in it stays data (checked under bash 3.2, #895). The
    # launch keeps its path in a global instead; both are safe. Do not re-fix.
    trap "release_session_lock $(printf '%q' "$meta")" EXIT
    # .cs/local is gitignored and born on the first open, so a session cloned
    # here and never opened has none; the pre-open hook and the vault record
    # live in it. Made before anything moves, so a failure changes nothing.
    mkdir -p "$meta/local"
    mnt="$meta/vault-mnt"
    container=$(_encrypt_container_path "$name")

    # Where Claude Code kept this session's conversations so far.
    transcripts=$(_plain_claude_project_dir "$SESSIONS_ROOT/$name")

    # cs asks once and hands the password to diskutil on stdin, for the
    # create and for the attach: it is never an argument, and diskutil is
    # never left to ask, which it does in a dialog offering the keychain.
    printf '%s\n' "$(_vault_prompt_head "$name" "$SESSIONS_ROOT/$name" 'new vault')" >&2
    _encrypt_read_secret "$(_vault_prompt_ask 'password')"
    password=$CS_SECRET_REPLY
    [ -n "$password" ] || error "$name: no password entered; the session is unchanged."
    _encrypt_read_secret "$(_vault_prompt_ask 'again')"
    again=$CS_SECRET_REPLY
    CS_SECRET_REPLY=""
    [ "$password" = "$again" ] || error "$name: the two passwords differ; the session is unchanged."
    again=""

    mkdir -p "$(dirname "$container")"
    out=$(printf '%s' "$password" | diskutil image create blank --encrypt --stdinpassphrase \
        --format UDSB --size 50g --volumeName "cs-$name" --fs APFS "$container" 2>&1) \
        || error "$name: diskutil could not create the vault; the session is unchanged. diskutil said: $out"
    mkdir -p "$mnt"
    if ! out=$(printf '%s' "$password" | diskutil image attach --stdinpassphrase --nobrowse \
        --mountPoint "$mnt" "$container" 2>&1); then
        rmdir "$mnt" 2>/dev/null || true
        error "$name: diskutil could not attach $container; the session is unchanged. Delete the container before retrying. diskutil said: $out"
    fi
    password=""
    # Spotlight indexing holds files open and turns a detach busy.
    touch "$mnt/.metadata_never_index"

    moved=$(_encrypt_moves "$meta" | awk '{ printf " .cs/%s", $1 }')
    _encrypt_move_content "$name" "$meta"
    # The conversations go last, so a .cs/ move that fails leaves them where
    # Claude Code reads them. A copy that stops leaves them whole outside and
    # the vault mounted; a removal that stops leaves whole copies in the
    # vault, so cs -encrypt names what is left and finishes. A project dir
    # that is a link is left alone: moving the link would move no conversation.
    # Conversations a running claude writes stay too, for the next open, and
    # so does a folder cs cannot read all of, or one that holds another path's
    # conversations.
    if [ ! -d "$transcripts" ] || [ -L "$transcripts" ]; then
        :
    elif _conversations_move_refusal "$SESSIONS_ROOT/$name" "$transcripts" "The next open moves them once it has ended."; then
        warn "$name: $CS_MOVE_REFUSAL"
        stayed="claude"
        [ -z "$CS_PLAIN_WRITER_FILE" ] || stayed="claude-unknown"
    elif _unreadable_conversations_refusal "$transcripts" "$mnt/claude-config/projects/${transcripts##*/}"; then
        warn "$name: $CS_MOVE_REFUSAL"
        stayed="unreadable"
    elif _foreign_conversation_refusal "$SESSIONS_ROOT/$name" "$transcripts"; then
        warn "$name: $CS_MOVE_REFUSAL"
        stayed="other-path"
    else
        _move_conversations_into_vault "$transcripts" "$mnt/claude-config/projects/${transcripts##*/}" || move_rc=$?
        case "$move_rc" in
            0) ;;
            1) error "$name: could not copy the session's conversations ($transcripts) into the vault. They are all still there, whole, and the vault holds $(_conversations_in_vault_after_a_stop). Already moved:${moved:- nothing}. The vault is still mounted at .cs/vault-mnt; finish by hand or move those back, then detach it. cp said: $CS_MOVE_ERROR" ;;
            2) _warn_conversations_left_outside "$name" "$transcripts"; stayed="unremoved" ;;
            *) error "_move_conversations_into_vault returned $move_rc for $transcripts" ;;
        esac
    fi
    for sub in $CS_VAULT_LINKS; do
        ln -s "vault-mnt/$sub" "$meta/$sub"
    done
    _encrypt_write_pre_open "$meta" "$container"
    printf '%s\n' "$container" > "$meta/local/vault"
    ( CLAUDE_SESSION_META_DIR="$meta" _tag_mutate add encrypted ) \
        || error "$name: the vault is built but the encrypted tag could not be written; add it with cs $name -tag add encrypted."

    out=$(diskutil eject "$mnt" 2>&1) \
        || error "$name: encrypted, but the vault would not detach; run diskutil eject $mnt before opening it. diskutil said: $out"
    info "$name is encrypted. Every open asks for the vault password; the vault detaches when the last conversation ends."
    echo
    echo "Still in plaintext from before today; remove them by hand if they matter:"
    echo "  - this session's lines in ~/.claude/history.jsonl"
    echo "  - its project entries in ~/.claude.json and that file's backups"
    echo "  - conversations started from another folder, such as a subfolder of the session, in ~/.claude/projects/"
    echo "  - what else Claude Code kept for its conversations under ~/.claude (file-history/, tasks/, debug/, paste-cache/)"
    echo "  - git history of anything committed before, and backups or snapshots"
    if [ -L "$transcripts" ]; then
        echo "  - this session's conversations: $transcripts is a link, so cs left it, and the folder it points to, outside the vault"
    fi
    case "$stayed" in
        "") ;;
        claude) echo "  - this session's conversations: a claude was running in the session outside cs, so cs left them in $transcripts; the next open moves them once it has ended" ;;
        claude-unknown) echo "  - this session's conversations: cs could not tell whether a running claude writes them, so cs left them in $transcripts; the next open moves them once that process has ended" ;;
        unreadable) echo "  - this session's conversations: cs could not read every folder under $transcripts, so cs left them there; the next open moves them once it can" ;;
        other-path) echo "  - this session's conversations: $transcripts holds a conversation of another path too, so cs left the whole folder outside the vault" ;;
        unremoved) echo "  - what cs could not remove from $transcripts: the vault holds whole copies of this session's conversations, and what is left there is a copy in plain text" ;;
        *) error "cs -encrypt has no closing line for conversations left outside the vault as '$stayed'" ;;
    esac
    echo "Always in plaintext:"
    echo "  - .cs/summary.md and .cs/brief.md"
}
