# ABOUTME: cs -encrypt: moves an existing, closed session's private files into an
# ABOUTME: hdiutil-encrypted sparsebundle and links the four vault names into its mount.

# Where the container lives: outside every session directory, so neither
# cs -rm nor the autosave snapshot ever reaches it.
_encrypt_container_path() {  # session_name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# Every precondition, checked before anything is written.
_encrypt_refuse() {  # session_name
    local name="$1" dir meta sub container
    [ "$(uname -s)" = "Darwin" ] || error "cs -encrypt needs macOS (hdiutil); Linux is not supported yet."
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
_encrypt_write_pre_open() {  # meta_dir, container
    local hook="$1/local/pre-open"
    {
        echo '#!/bin/bash'
        echo '# Written by cs -encrypt: mounts this session vault, asking for its password at every open.'
        echo 'set -euo pipefail'
        printf 'container=%q\n' "$2"
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
    if mounted && ! hdiutil detach "$mnt"; then
        echo "cs: the vault is still mounted from a conversation that ended, and it would not detach. Close whatever holds it, run: hdiutil detach $mnt" >&2
        exit 1
    fi
fi
if ! { [ -t 0 ] || [ "${CS_ASSUME_TTY:-}" = "1" ]; }; then
    echo "cs: this session is encrypted and needs a terminal to ask for the vault password." >&2
    exit 1
fi
hdiutil attach -nobrowse -mountpoint "$mnt" "$container"
EOF
    } > "$hook"
    chmod +x "$hook"
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
    hdiutil detach "$mnt" >/dev/null 2>&1 && return 0
    _vault_mountpoint_if_mounted "$meta" >/dev/null || return 0
    warn "The vault is still mounted at $mnt; the next open detaches it, or run: hdiutil detach $mnt"
}

run_encrypt() {
    [ $# -eq 1 ] || error "Usage: cs -encrypt <name>"
    local name="$1" meta container mnt sub taken=0
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

    mkdir -p "$(dirname "$container")"
    info "Creating the encrypted container; hdiutil asks for the new password."
    hdiutil create -size 50g -type SPARSEBUNDLE -fs APFS -encryption AES-256 \
        -volname "cs-$name" "$container" \
        || error "$name: hdiutil create failed; the session is unchanged."
    mkdir -p "$mnt"
    info "Mounting it; hdiutil asks for the password again."
    if ! hdiutil attach -nobrowse -mountpoint "$mnt" "$container"; then
        rmdir "$mnt" 2>/dev/null || true
        error "$name: hdiutil could not attach $container; the session is unchanged. Delete the container before retrying."
    fi
    # Spotlight indexing holds files open and turns a detach busy.
    touch "$mnt/.metadata_never_index"

    _encrypt_move_content "$name" "$meta"
    for sub in $CS_VAULT_LINKS; do
        ln -s "vault-mnt/$sub" "$meta/$sub"
    done
    _encrypt_write_pre_open "$meta" "$container"
    printf '%s\n' "$container" > "$meta/local/vault"
    ( CLAUDE_SESSION_META_DIR="$meta" _tag_mutate add encrypted ) \
        || error "$name: the vault is built but the encrypted tag could not be written; add it with cs $name -tag add encrypted."

    hdiutil detach "$mnt" \
        || error "$name: encrypted, but the vault would not detach; run hdiutil detach $mnt before opening it."
    info "$name is encrypted. Every open asks for the vault password; the vault detaches when the last conversation ends."
    echo "cs could not move copies made before today; remove them by hand if they matter:"
    echo "  - this session's transcripts in ~/.claude/projects/"
    echo "  - its lines in ~/.claude/history.jsonl"
    echo "  - its project entries in ~/.claude.json and that file's backups"
    echo "  - .cs/summary.md and .cs/brief.md, which stay plaintext"
    echo "  - git history of anything committed before, and backups or snapshots"
}
