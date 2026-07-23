# ABOUTME: Parallel feature worktrees: name parsing, bootstrap, create, merge, and record fusion.
# ABOUTME: Backs 'cs <base>@<feature>' and 'cs <base> --merge <feature>'.

cs_split_worktree_name() {
    local name="$1"
    case "$name" in
        *@*) ;;
        *) return 1 ;;
    esac
    CS_WT_BASE="${name%%@*}"
    CS_WT_TASK="${name#*@}"
    if [ -z "$CS_WT_BASE" ]; then
        error "Session name cannot be empty before '@' (expected <base>@<feature>)"
    fi
    validate_session_name "$CS_WT_BASE"
    if [ -z "$CS_WT_TASK" ] || ! [[ "$CS_WT_TASK" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "Worktree feature name must contain only alphanumeric characters, hyphens, underscores, and dots"
    fi
    return 0
}

# Create the .cs/ skeleton inside a worktree whose repo does not track .cs/
# (ignored mode). Leaves the checkout's CLAUDE.md alone — in these repos it
# is the project's own tracked file.
bootstrap_worktree_meta() {
    local wt_dir="$1" base_name="$2" task="$3"
    mkdir -p "$wt_dir/.cs"/{local,memory}
    cat > "$wt_dir/.cs/README.md" << EOF
---
status: active
created: $(date '+%Y-%m-%d')
tags: [worktree]
aliases: ["$base_name@$task"]
---
# Session: $base_name@$task

Feature worktree of session '$base_name' on branch cs/$task.

## Objective

[Describe this feature]
EOF
    cat > "$wt_dir/.cs/local/session.log" << EOF
Claude Code Session Log
Session: $base_name@$task
Started: $(date '+%Y-%m-%d %H:%M:%S')

================================================================================

EOF
    ensure_narrative_file "$wt_dir"
}

# True when a checkout has uncommitted changes to tracked files (staged or
# unstaged). Untracked files are a separate question with per-site messages.
_tree_is_dirty() {
    ! git -C "$1" diff --quiet 2>/dev/null \
        || ! git -C "$1" diff --cached --quiet 2>/dev/null
}

# Resolve a symlinked directory to its real path, portably. BSD readlink gained
# -f only in macOS 12.3; cd+pwd -P follows the link on every platform, and the
# fallback keeps the original path rather than aborting under set -e.
_resolve_symlink_dir() {
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# Resolve a session name to its real directory (adopted sessions are
# symlinks into the project checkout). Prints the resolved path.
_resolve_session_dir() {
    local dir="$SESSIONS_ROOT/$1"
    [ -L "$dir" ] && dir="$(_resolve_symlink_dir "$dir")"
    printf '%s\n' "$dir"
}

# Gate worktree creation on the base checkout's tracked state. Runs in the
# main shell so a declined consent can exit cs cleanly (the creator is
# command-substituted, where an exit only leaves the subshell). Clean base
# returns; dirty base asks for informed consent on interactive terminals
# (the feature branches from the last commit and will not include uncommitted
# changes) and refuses everywhere else.
confirm_clean_worktree_base() {
    local base_dir="$1" base_name="$2"
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    _tree_is_dirty "$base_dir" || return 0
    if cs_interactive; then
        printf '\n    %b⚠%b  %s has uncommitted changes; the feature branches from the\n       last commit and will not include them.\n' \
            "$YELLOW" "$NC" "$base_name"
        printf '    Continue?  %b[y/N]%b %b›%b ' "$DIM" "$NC" "$GOLD" "$NC"
        local consent=""
        read -r consent || consent=""
        if [[ ! "$consent" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            exit 0
        fi
    else
        error "Session '$base_name' has uncommitted changes; commit them first (a worktree materializes committed state only)"
    fi
}

# Create a linked git worktree of a base session as a sibling session dir.
# The caller gates dirty base state via confirm_clean_worktree_base. Prints
# the new worktree path.
create_worktree_session() {
    local base_dir="$1" base_name="$2" task="$3"
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    if ! git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1; then
        error "Session '$base_name' has no git repo; worktrees need one"
    fi
    if [ -f "$base_dir/.git" ]; then
        error "Session '$base_name' is itself a worktree; create features from the main checkout"
    fi
    # Dirty-state gating happens in the caller (confirm_clean_worktree_base):
    # this function runs command-substituted, where an exit cannot stop cs.
    local untracked
    untracked=$(git -C "$base_dir" ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
    if [ -n "$untracked" ]; then
        warn "Untracked files will not appear in the worktree:" >&2
        printf '%s\n' "$untracked" >&2
    fi

    if git -C "$base_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        git -C "$base_dir" worktree add "$wt_dir" "$branch" >/dev/null \
            || error "git worktree add failed (is branch '$branch' checked out in another worktree?)"
    else
        git -C "$base_dir" worktree add -b "$branch" "$wt_dir" >/dev/null \
            || error "git worktree add failed"
    fi

    local mode="tracked"
    if [ -z "$(git -C "$base_dir" ls-files -- .cs 2>/dev/null)" ]; then
        mode="ignored"
        bootstrap_worktree_meta "$wt_dir" "$base_name" "$task"
    fi

    # The protocol file is normally gitignored, so no worktree inherits it
    # through git in either mode; write this worktree's own copy. The FILE
    # only — never touch a .gitignore here (ignored-mode worktrees check out
    # project repos whose .gitignore is theirs). Guarded: a repo that
    # (against CC convention) TRACKS CLAUDE.local.md checks its own copy
    # into the worktree; only overwrite when absent or already cs's own.
    if [ ! -f "$wt_dir/CLAUDE.local.md" ] \
        || grep -q 'cs:session-protocol' "$wt_dir/CLAUDE.local.md"; then
        write_session_claude_md "$wt_dir"
    fi

    # Cover the protocol file via the clone-local info/exclude in BOTH
    # modes. In ignored mode the checkout's .gitignore belongs to the
    # project and is never touched. In tracked mode the file is normally
    # covered by the base's own .gitignore entry — but a base committed
    # before the CLAUDE.local.md backfill (and never relaunched since)
    # checks out a .gitignore missing it, which would otherwise leave the
    # file untracked and block `cs <base> --merge`'s preflight. The exclude
    # entry is clone-local and harmless alongside a .gitignore entry (never
    # tracked, never dirties the task branch; shared with the base checkout
    # through the common git dir).
    local exclude
    exclude=$( (cd "$wt_dir" && git rev-parse --git-path info/exclude) 2>/dev/null || echo "" )
    # A worktree's git-path resolves to the common git dir, which git reports as
    # an absolute path — drive-letter form (C:/... or C:\...) under Git Bash.
    # Matching only /* would read that as relative and prepend $wt_dir, writing
    # the exclude entry to a nonsense path and leaving the protocol file
    # untracked, which then blocks `cs <base> --merge`.
    case "$exclude" in
        "") : ;;
        /*) : ;;
        [A-Za-z]:[\\/]*) : ;;
        *) exclude="$wt_dir/$exclude" ;;
    esac
    if [ -n "$exclude" ]; then
        mkdir -p "${exclude%/*}" 2>/dev/null || true
        if ! grep -qF 'CLAUDE.local.md' "$exclude" 2>/dev/null; then
            echo 'CLAUDE.local.md' >> "$exclude"
        fi
    fi

    local state="$wt_dir/.cs/local/state"
    _set_local_state "$state" claude_session_id "$(_alloc_uuid)"
    _set_local_state "$state" claude_session_color "$(_alloc_random_color)"
    _set_local_state "$state" task_branch "$branch"
    _set_local_state "$state" cs_mode "$mode"
    _set_local_state "$state" cs_base "$base_name"

    setup_auto_memory "$wt_dir"

    echo "$wt_dir"
}

# Merge a feature worktree's branch back into the base session, fuse session
# records, and remove the worktree. Explicit and user-invoked only; every
# preflight refuses rather than committing on the user's behalf.
merge_worktree_session() {
    local base_name="$1" task="$2"
    local base_dir
    base_dir=$(_resolve_session_dir "$base_name")
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"

    local wt_name="$base_name@$task"
    if [ "${CLAUDE_SESSION_NAME:-}" = "$wt_name" ]; then
        error "Cannot merge '$wt_name' from inside that worktree session. Close '$wt_name', then run: cs $base_name --merge $task (from '$base_name' or a free terminal)"
    fi

    local lock lock_session pid
    for lock_session in "$base_name" "$wt_name"; do
        if [ "$lock_session" = "$base_name" ]; then
            lock="$base_dir/.cs/session.lock"
        else
            lock="$wt_dir/.cs/session.lock"
        fi
        if [ -f "$lock" ]; then
            pid=$(cat "$lock" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                if session_lock_owned_by_invoker "$lock_session" "$pid"; then
                    continue
                fi
                error "A session is open (PID $pid, $lock); close it before merging"
            fi
        fi
    done

    if _tree_is_dirty "$wt_dir"; then
        error "Worktree has uncommitted changes; commit them in $wt_dir first (cs never commits for you)"
    fi
    local wt_untracked
    wt_untracked=$(git -C "$wt_dir" ls-files --others --exclude-standard 2>/dev/null || true)
    if [ -n "$wt_untracked" ]; then
        error "Worktree has untracked files that removal would destroy; commit or remove them first:
$wt_untracked"
    fi
    if _tree_is_dirty "$base_dir"; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi

    setup_merge_attributes "$base_dir"

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)

    if git -C "$base_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
        info "Branch $branch is already merged; cleaning up"
    else
        if [ "$mode" = "tracked" ]; then
            local mb
            mb=$(git -C "$base_dir" merge-base HEAD "$branch" 2>/dev/null || echo "")
            if [ -n "$mb" ] \
                && ! git -C "$base_dir" diff --quiet "$mb" "$branch" -- .cs/memory/MEMORY.md 2>/dev/null; then
                warn "MEMORY.md changed on $branch; merge=ours keeps the base copy. Review: git -C \"$base_dir\" diff $mb $branch -- .cs/memory/MEMORY.md"
            fi
        fi
        if ! git -C "$base_dir" merge --no-edit "$branch"; then
            error "Merge conflicts in $base_dir; resolve and commit (or git merge --abort), then re-run: cs $base_name --merge $task"
        fi
    fi

    if [ "$mode" = "ignored" ]; then
        fuse_session_records "$wt_dir/.cs" "$base_dir/.cs"
    fi

    # --force: the worktree legitimately holds untracked files (.cs/local,
    # settings.local.json, the whole .cs in ignored mode) that our preflight
    # deliberately does not count as dirt.
    git -C "$base_dir" worktree remove --force "$wt_dir" \
        || error "git worktree remove failed for $wt_dir"
    git -C "$base_dir" branch -d "$branch" >/dev/null 2>&1 \
        || warn "Branch $branch was not deleted (not fully merged?)"

    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "worktree-merged" \
           --arg task "$task" \
        '{ts: $ts, event: $event, task: $task}' \
        >> "$base_dir/.cs/timeline.jsonl" 2>/dev/null || true
    info "Merged $branch and removed worktree $base_name@$task"
}

# Fuse session records from a worktree .cs into the base .cs (ignored mode:
# the repo does not track .cs/, so git merge cannot carry these). Applies the
# same semantics the merge drivers give tracked repos: union append for
# timeline/log/narratives, copy-never-overwrite for memory topic files,
# base-wins for MEMORY.md.
fuse_session_records() {
    local src="$1" dst="$2"
    local f base

    [ -f "$src/timeline.jsonl" ] && cat "$src/timeline.jsonl" >> "$dst/timeline.jsonl"
    # Worktrees never run migrate_session, so a task branch created before the
    # log moved to .cs/local/ still keeps its audit trail at .cs/logs/; fuse
    # whichever the worktree has into the base's machine-local log.
    local srclog
    for srclog in "$src/local/session.log" "$src/logs/session.log"; do
        if [ -f "$srclog" ]; then
            mkdir -p "$dst/local"
            { echo ""; cat "$srclog"; } >> "$dst/local/session.log"
            break
        fi
    done

    mkdir -p "$dst/memory"
    for f in "$src"/memory/narrative.*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [ -f "$dst/memory/$base" ]; then
            # Append the body past the closing --- of the YAML frontmatter.
            # A file not opening with --- has no frontmatter (whole file is
            # body); counting stops at 2 so a --- horizontal rule in the
            # body stays body instead of truncating the append.
            awk 'NR==1 && $0 != "---" {c=2} /^---$/ && c < 2 {c++; next} c >= 2 {print}' \
                "$f" >> "$dst/memory/$base"
        else
            cp "$f" "$dst/memory/$base"
        fi
    done

    for f in "$src"/memory/*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            MEMORY.md) continue ;;
            narrative.*.md) continue ;;
        esac
        if [ -f "$dst/memory/$base" ]; then
            warn "memory/$base already exists in the base; skipped"
        else
            cp "$f" "$dst/memory/$base"
        fi
    done

    if [ -f "$src/memory/MEMORY.md" ]; then
        info "MEMORY.md index lines from the feature were not merged (base copy kept)"
    fi
}

# Ensure auto memory directory exists and migrate from default location
