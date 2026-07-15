# ABOUTME: cs -archive / cs -unarchive: the tracked .cs/archived marker that
# ABOUTME: hides finished sessions from default listings until reopened.

# Resolve a session name for the archive verbs. Sets ARCHIVE_DIR (real path,
# adopted-session symlinks followed) and ARCHIVE_MARKER; errors on an unknown
# session. Called directly, never in command substitution — error must exit
# the caller, not a subshell.
_archive_resolve() {  # name
    ARCHIVE_DIR="$SESSIONS_ROOT/$1"
    if [ ! -d "$ARCHIVE_DIR" ] && [ ! -L "$ARCHIVE_DIR" ]; then
        error "No such session: $1"
    fi
    [ -L "$ARCHIVE_DIR" ] && ARCHIVE_DIR="$(_resolve_symlink_dir "$ARCHIVE_DIR")"
    ARCHIVE_MARKER="$ARCHIVE_DIR/.cs/archived"
}

# True when a session directory carries the archived marker. Presence is the
# whole state; the file's content is advisory.
_session_is_archived() {  # session_dir
    [ -f "$1/.cs/archived" ]
}

run_archive() {
    local name="" force="" arg
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force="true" ;;
            -*) error "Unknown archive option: $arg. Usage: cs -archive <name> [--force]" ;;
            *)
                [ -z "$name" ] || error "Usage: cs -archive <name> [--force]"
                name="$arg"
                ;;
        esac
    done
    [ -n "$name" ] || error "Usage: cs -archive <name> [--force]"
    _archive_resolve "$name"
    if [ -f "$ARCHIVE_MARKER" ]; then
        info "Already archived: $name"
        return 0
    fi
    if [ -z "$force" ] && session_is_live "$ARCHIVE_DIR/.cs"; then
        error "Session '$name' is live (pid $(read_lock_pid "$ARCHIVE_DIR/.cs")); use --force to archive anyway"
    fi
    printf 'archived: %s by %s\n' "$(date +%Y-%m-%d)" "$(cs_actor_slug)" > "$ARCHIVE_MARKER"
    info "Archived: $name (opening it restores it; or run 'cs -unarchive $name')"
}

run_unarchive() {
    local name="${1:-}"
    [ -n "$name" ] || error "Usage: cs -unarchive <name>"
    _archive_resolve "$name"
    if [ ! -f "$ARCHIVE_MARKER" ]; then
        info "Not archived: $name"
        return 0
    fi
    rm -f "$ARCHIVE_MARKER"
    info "Unarchived: $name"
}

# One dimmed line noting how many archived sessions the default listing hid.
_list_archived_trailer() {  # count
    [ "$1" -gt 0 ] || return 0
    echo -e "${COMMENT}$1 archived (cs -list --archived)${NC}"
}
