# ABOUTME: Dependency checks (claude binary) and session-name validation.
# ABOUTME: Rejects unsafe names before any filesystem work.

check_dependencies() {
    local missing=()

    # Extract just the binary name (first word) for the check
    local claude_bin
    claude_bin="${CLAUDE_CODE_BIN%% *}"
    command -v "$claude_bin" >/dev/null 2>&1 || missing+=("claude-code")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required dependencies: ${missing[*]}"
    fi
}

# Validate session name
validate_session_name() {
    local name="$1"

    if [ -z "$name" ]; then
        error "Session name cannot be empty"
    fi

    case "$name" in
        .|..) error "Session name cannot be '.' or '..'" ;;
    esac

    if ! [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "Session name must contain only alphanumeric characters, hyphens, underscores, and dots"
    fi
}

# Split a worktree session name <base>@<task> into CS_WT_BASE / CS_WT_TASK.
# Returns 1 for plain names (no @). Errors out when either half is invalid.
# @ is safe as a separator: validate_session_name has never admitted it, so
# no existing session name can contain one.
