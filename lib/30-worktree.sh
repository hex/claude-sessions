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

# Untracked files in a worktree that removal would actually destroy, one per
# line. cs writes its own bookkeeping into every worktree — the whole .cs tree
# in ignored mode, plus the settings and protocol files — and none of it is the
# user's to commit: ignored-mode fusion carries .cs into the base before the
# removal, and the removal passes --force precisely because these are expected.
# The merge gate and the readiness screen MUST read from this one definition;
# when they disagreed, a worktree predating the cs exclude reported blocked on a
# merge that would have gone straight through.
_worktree_untracked_at_risk() {  # wt_dir
    git -C "$1" ls-files --others --exclude-standard 2>/dev/null \
        | grep -v -e '^\.cs/' -e '^\.claude/settings\.local\.json$' -e '^CLAUDE\.local\.md$' \
        || true
}

# Print the PID of a live lock on a session that the invoker does not own:
# empty when the lock is absent, its process is dead, or the lock is the
# invoking conversation's own (session_lock_owned_by_invoker). The merge verb
# and the integrate entry both refuse on a non-empty answer.
_foreign_live_lock_pid() {  # session_name lock_file
    local pid
    [ -f "$2" ] || return 0
    pid=$(cat "$2" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
    session_lock_owned_by_invoker "$1" "$pid" && return 0
    printf '%s\n' "$pid"
}

# Absolute form of a `git rev-parse` path answer (--git-dir, --git-common-dir).
# git answers relative to the checkout from a main worktree and absolute from
# a linked one; every path built on the answer (the integrate mutex, the temp
# worktree) must resolve the same from both.
_git_path_abs() {  # checkout_dir rev-parse-flag
    local p
    p=$(git -C "$1" rev-parse "$2" 2>/dev/null) || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *) printf '%s\n' "$1/$p" ;;
    esac
}

# The same merge policy setup_merge_attributes (lib/45-migrate.sh:4) gives a
# checkout, written clone-local: merge.ours.driver into the shared config and
# the three attribute lines into <common>/info/attributes, which every
# worktree of the repo reads and which dirties no tree. The temp worktree
# checks out whatever .gitattributes the base has committed, which may lack
# these lines; without them tracked-mode timeline and narrative appends on
# both sides conflict instead of union-merging.
_setup_merge_attributes_clone_local() {  # base_dir common_dir
    git -C "$1" config merge.ours.driver true 2>/dev/null || true
    local attrs="$2/info/attributes"
    mkdir -p "$2/info"
    if ! grep -q 'MEMORY\.md merge=ours' "$attrs" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$attrs"
    fi
    if ! grep -q 'timeline\.jsonl merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/timeline.jsonl merge=union\n' >> "$attrs"
    fi
    if ! grep -q 'narrative\.\*\.md merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/memory/narrative.*.md merge=union\n' >> "$attrs"
    fi
}

# Tracked-.cs mode: MEMORY.md merges with merge=ours, so a change to it on the
# feature is silently dropped by the merge that follows; say so first.
_warn_memory_index_changed() {  # base_dir ref
    local mb
    mb=$(git -C "$1" merge-base HEAD "$2" 2>/dev/null || echo "")
    if [ -n "$mb" ] \
        && ! git -C "$1" diff --quiet "$mb" "$2" -- .cs/memory/MEMORY.md 2>/dev/null; then
        warn "MEMORY.md changed on $2; merge=ours keeps the base copy. Review: git -C \"$1\" diff $mb $2 -- .cs/memory/MEMORY.md"
    fi
}

# Print the task name of every verified feature worktree of a base, one per
# line. Glob the sessions root then ask git to confirm each candidate — the
# reverse direction would enumerate the main checkout, and for an adopted base
# it would also enumerate the underlying project's own worktrees, which are not
# cs sessions at all. Asking git for the path on both sides is what makes this
# survive a directory whose two spellings differ, exactly as
# _doctor_check_worktrees does.
_worktree_features() {  # base_name
    local base_name="$1"
    local base_dir d name task d_real registered
    base_dir=$(_resolve_session_dir "$base_name")
    [ -d "$base_dir" ] || return 0
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0

    registered=$(git -C "$base_dir" worktree list --porcelain 2>/dev/null || true)

    for d in "$SESSIONS_ROOT/$base_name"@*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        task="${name#*@}"
        [ -n "$task" ] || continue
        d_real=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) \
            || d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
        case "
$registered
" in
            *"
worktree $d_real
"*) printf '%s\n' "$task" ;;
        esac
    done
}

# Print one tab-separated readiness record for a base's feature worktree:
#   task branch ahead merged ff wt_dirty untracked base_dirty lock state
# Every fact is computed by the function the real gate calls, so the answer can
# never disagree with the refusal the merge would produce.
_feature_readiness() {  # base_name task
    local base_name="$1" task="$2"
    local base_dir wt_dir wt_name branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_name="$base_name@$task"
    wt_dir="$SESSIONS_ROOT/$wt_name"
    branch=$(_read_local_state "$wt_dir/.cs/local/state" task_branch)
    [ -n "$branch" ] || branch="cs/$task"

    local ahead=0 merged=0 ff=0 wt_dirty=0 untracked=0 base_dirty=0 lock="none"

    ahead=$(git -C "$base_dir" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)

    # "Already merged" needs the tip STRICTLY behind base HEAD. A fresh
    # worktree's branch sits AT base HEAD, where is-ancestor is also true, and
    # merge_worktree_session reads is-ancestor as "already merged; cleaning up"
    # and then removes the worktree. Same guard as _doctor_check_worktrees.
    if git -C "$base_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null \
        && [ "$(git -C "$base_dir" rev-parse "$branch" 2>/dev/null)" \
             != "$(git -C "$base_dir" rev-parse HEAD 2>/dev/null)" ]; then
        merged=1
    fi

    # A merge fast-forwards when base HEAD is already an ancestor of the
    # branch: `git merge --no-edit` carries no --no-ff, so no merge commit is
    # written and the screen must not promise one.
    if git -C "$base_dir" merge-base --is-ancestor HEAD "$branch" 2>/dev/null; then
        ff=1
    fi

    _tree_is_dirty "$wt_dir" && wt_dirty=1
    _tree_is_dirty "$base_dir" && base_dirty=1

    local others
    others=$(_worktree_untracked_at_risk "$wt_dir")
    if [ -n "$others" ]; then
        untracked=$(printf '%s\n' "$others" | wc -l | tr -d '[:space:]')
    fi

    # Gate order: base lock, then worktree lock. A lock owned by this invoker
    # is exempt, exactly as the merge gate treats it.
    local lock_session lock_file pid
    for lock_session in "$base_name" "$wt_name"; do
        if [ "$lock_session" = "$base_name" ]; then
            lock_file="$base_dir/.cs/session.lock"
        else
            lock_file="$wt_dir/.cs/session.lock"
        fi
        [ -f "$lock_file" ] || continue
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
        session_lock_owned_by_invoker "$lock_session" "$pid" && continue
        if [ "$lock_session" = "$base_name" ]; then lock="base"; else lock="worktree"; fi
        break
    done

    # State is the first blocker merge_worktree_session would hit, in its order.
    local state="ready"
    if [ "$lock" != "none" ]; then
        state="locked"
    elif [ "$wt_dirty" = 1 ]; then
        state="dirty"
    elif [ "$untracked" != 0 ]; then
        state="untracked"
    elif [ "$base_dirty" = 1 ]; then
        state="base-dirty"
    elif [ "$merged" = 1 ]; then
        state="merged"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$task" "$branch" "$ahead" "$merged" "$ff" \
        "$wt_dirty" "$untracked" "$base_dirty" "$lock" "$state"
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
    # A worktree's git-path resolves to the common git dir, which git reports
    # as an absolute path. Reading that as relative would prepend $wt_dir,
    # writing the exclude entry to a nonsense path and leaving the protocol file
    # untracked, which then blocks `cs <base> --merge`.
    case "$exclude" in
        "") : ;;
        /*) : ;;
        *) exclude="$wt_dir/$exclude" ;;
    esac
    if [ -n "$exclude" ]; then
        mkdir -p "${exclude%/*}" 2>/dev/null || true
        if ! grep -qF 'CLAUDE.local.md' "$exclude" 2>/dev/null; then
            echo 'CLAUDE.local.md' >> "$exclude"
        fi
        if ! grep -qF '.claude/settings.local.json' "$exclude" 2>/dev/null; then
            echo '.claude/settings.local.json' >> "$exclude"
        fi
        # Ignored mode means .cs is not TRACKED — it does not mean the project
        # ignores it. Where the project's .gitignore never named .cs/, the
        # skeleton bootstrap_worktree_meta just wrote shows up as untracked in
        # every git status the user runs here. Tracked mode must not get this
        # entry: there .cs belongs to the checkout.
        if [ "$mode" = "ignored" ] && ! grep -qF '.cs/' "$exclude" 2>/dev/null; then
            echo '.cs/' >> "$exclude"
        fi
    fi

    local state="$wt_dir/.cs/local/state"
    _set_local_state "$state" claude_session_id "$(_alloc_uuid)"
    _set_local_state "$state" claude_session_color "$(_alloc_random_color)"
    _set_local_state "$state" task_branch "$branch"
    _set_local_state "$state" cs_mode "$mode"
    _set_local_state "$state" cs_base "$base_name"

    setup_auto_memory "$wt_dir"

    # A feature worktree is a full cs session holding the same narrative, plans
    # and machine-local state as its base, so it gets the same privacy. cs
    # created this directory, so unlike an adopted session the ROOT is cs's to
    # set too. Kept here rather than left to migrate_session, which the worktree
    # open path deliberately never calls.
    _harden_session_meta "$wt_dir"
    chmod 700 "$wt_dir" 2>/dev/null || true

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
        pid=$(_foreign_live_lock_pid "$lock_session" "$lock")
        if [ -n "$pid" ]; then
            error "A session is open (PID $pid, $lock); close it before merging"
        fi
    done

    if _tree_is_dirty "$wt_dir"; then
        error "Worktree has uncommitted changes; commit them in $wt_dir first (cs never commits for you)"
    fi
    # Everything the filter keeps still refuses: the point of the gate is work
    # the user would lose.
    local wt_untracked
    wt_untracked=$(_worktree_untracked_at_risk "$wt_dir")
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
            _warn_memory_index_changed "$base_dir" "$branch"
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

    _terminate_jsonl "$base_dir/.cs/timeline.jsonl"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "worktree-merged" \
           --arg task "$task" \
        '{ts: $ts, event: $event, task: $task}' \
        >> "$base_dir/.cs/timeline.jsonl" 2>/dev/null || true
    info "Merged $branch and removed worktree $base_name@$task"
}

# Remove the temp worktree and release the mutex on every exit path of
# integrate_feature_worktree, including error's exit 1. Globals because an
# EXIT trap runs after the function's locals are gone.
_integrate_cleanup() {
    if [ -n "${_INTEGRATE_TMP:-}" ]; then
        # Remove if present, then prune regardless: a directory gone with its
        # registration surviving is exactly what prune exists for.
        if [ -d "$_INTEGRATE_TMP" ]; then
            git -C "$_INTEGRATE_BASE_DIR" worktree remove --force "$_INTEGRATE_TMP" >/dev/null 2>&1 \
                || rm -rf "$_INTEGRATE_TMP"
        fi
        git -C "$_INTEGRATE_BASE_DIR" worktree prune >/dev/null 2>&1 || true
    fi
    [ -n "${_INTEGRATE_LOCK:-}" ] && rmdir "$_INTEGRATE_LOCK" 2>/dev/null
    return 0
}

# Integrate a feature worktree's captured commit into the base session while
# the feature stays open: merge base HEAD + <sha> in a temporary detached
# worktree, run the gates there, fast-forward the base onto the result. Removes
# nothing — the worktree, the branch and the feature session all remain; the
# merge verb retires them later. Backs the unadvertised
# `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate...>`
# that skills/finish/scripts/finish.sh drives. Every refusal is an error that
# names the next command.
integrate_feature_worktree() {  # base_name task sha [--from-remote] -- gate...
    local usage="Usage: cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3"
    shift 3
    local from_remote=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-remote) from_remote=1; shift ;;
            --) shift; break ;;
            *) error "$usage" ;;
        esac
    done
    [ $# -gt 0 ] || error "$usage (a gate command is required; pass -- true to run none)"

    local base_dir wt_dir branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_dir="$SESSIONS_ROOT/$base_name@$task"
    branch="cs/$task"
    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    # Herestring, not a pipe: grep -q's early exit would SIGPIPE the writer
    # and pipefail would read that as "not registered".
    local features
    features=$(_worktree_features "$base_name")
    grep -qxF -- "$task" <<< "$features" \
        || error "$wt_dir is not a registered worktree of $base_name (see: git -C \"$base_dir\" worktree list)"

    # Only the base lock matters: the feature worktree is never touched, so
    # its conversation may stay open. A live base that is not this
    # conversation is a refusal, never a wait.
    local pid
    pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs/session.lock")
    [ -z "$pid" ] || error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"

    sha=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    if [ -n "$from_remote" ]; then
        local base_branch
        base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null) \
            || error "Base checkout is detached; check out the branch the PR targets, then re-run"
        git -C "$base_dir" merge-base --is-ancestor "$sha" "refs/remotes/origin/$base_branch" 2>/dev/null \
            || error "$sha is not reachable from origin/$base_branch; run: git -C \"$base_dir\" fetch origin, then check the PR's base branch"
    else
        git -C "$base_dir" merge-base --is-ancestor "$sha" "$branch" 2>/dev/null \
            || error "$sha is not reachable from $branch; capture the feature HEAD again"
    fi
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'already-integrated %s %s\n' "$task" "$sha"
        return 0
    fi

    if _tree_is_dirty "$base_dir"; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi
    local git_dir common
    git_dir=$(_git_path_abs "$base_dir" --git-dir) || error "Not a git checkout: $base_dir"
    common=$(_git_path_abs "$base_dir" --git-common-dir) || error "Not a git checkout: $base_dir"
    if git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
        || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        error "Base checkout has a merge or rebase in progress; finish or abort it, then re-run"
    fi

    # The mutex the autosave hook honours (hooks/autosave-commits.sh spells
    # the same path). Per-CHECKOUT, not per-clone: the base is always a main
    # checkout, so its --git-dir is the common dir, while a feature
    # worktree's autosave takes its own private gitdir's lock and never
    # contends with this integrate — the feature conversation stays open and
    # keeps snapshotting throughout a gate run. An existing directory is a
    # refusal, never stolen: a stale one is the user's to inspect and remove
    # (cs -doctor names it).
    local lock="$git_dir/cs/integrate.lock"
    mkdir -p "$git_dir/cs"
    # The base's own autosave takes this same lock for the length of one tree
    # write, so a refusal on the first try is far more often a snapshot in
    # flight than another integrate. Five tries a second apart outlast that
    # and still refuse promptly on a genuinely held lock.
    local tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            error "Another integrate or an in-flight autosave holds $lock; wait a few seconds and re-run. Remove that directory only if it persists with no cs running"
        fi
        sleep 1
    done
    _INTEGRATE_LOCK="$lock"
    _INTEGRATE_BASE_DIR="$base_dir"
    _INTEGRATE_TMP=""
    # EXIT alone is not enough: a TERM/INT'd bash skips the EXIT trap
    # (measured: exit 143, no cleanup), stranding the mutex and the temp.
    # Same shape as lib/75-launch.sh:112-113.
    trap '_integrate_cleanup' EXIT
    trap '_integrate_cleanup; exit 130' INT TERM

    _integrate_in_temp "$base_dir" "$wt_dir" "$task" "$sha" "$common" "$from_remote" "$@"
}

# The mutation half of integrate_feature_worktree, entered with the mutex
# held and the cleanup trap armed: merge base HEAD + <sha> in a temporary
# detached worktree under <common>/cs/finish/, run the gate argv there, then
# fast-forward the base onto the result. The fast-forward is the atomic
# "base has not moved" check; a red gate or a conflict leaves base exactly
# as it was. No hook of the project fires inside the temp (core.hooksPath
# points at an empty directory for the add and the merge): the gate argv is
# the project's gate, run explicitly.
_integrate_in_temp() {  # base_dir wt_dir task sha common from_remote gate...
    local base_dir="$1" wt_dir="$2" task="$3" sha="$4" common="$5" from_remote="$6"
    shift 6

    local B
    B=$(git -C "$base_dir" rev-parse HEAD)
    local tmp="$common/cs/finish/$task.$$"
    mkdir -p "$common/cs/finish"
    # /dev/null is not a directory on BSD, so hooks are silenced with a real
    # empty one.
    local no_hooks
    no_hooks=$(mktemp -d "${TMPDIR:-/tmp}/cs-nohooks.XXXXXX")
    if ! git -C "$base_dir" -c core.hooksPath="$no_hooks" worktree add --detach "$tmp" "$B" >/dev/null 2>&1; then
        rmdir "$no_hooks"
        error "git worktree add failed for $tmp"
    fi
    _INTEGRATE_TMP="$tmp"

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    if [ "$mode" = "tracked" ]; then
        _setup_merge_attributes_clone_local "$base_dir" "$common"
        _warn_memory_index_changed "$base_dir" "$sha"
    fi

    # --no-ff locally: the merge commit names the feature and is the audit
    # trail /finish leaves, and it gives the retire verb's ancestor check
    # something to find. --from-remote: the landing commit already exists on
    # origin and names the PR, so a fast-forward is the right shape there.
    local sha7 merge_status=0
    sha7=$(printf '%s' "$sha" | cut -c1-7)
    if [ -n "$from_remote" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-edit "$sha" >/dev/null 2>&1 || merge_status=$?
    else
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-ff --no-edit \
            -m "Merge feature $task ($sha7)" "$sha" >/dev/null 2>&1 || merge_status=$?
    fi
    if [ "$merge_status" != 0 ]; then
        rmdir "$no_hooks"
        local conflicts
        conflicts=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null || true)
        error "Merge of $sha conflicts with $base_dir at $B; base untouched. Conflicting paths:
${conflicts:-(none reported; see git -C \"$tmp\" status)}
Resolve on the feature branch (git merge <base branch> in $wt_dir), then re-run /finish $task"
    fi
    # An untracked file in the base colliding with a path the merge touches
    # passes _tree_is_dirty (tracked-only) and the temp merge itself, then
    # aborts the ff-only landing with a message that blames the wrong cause.
    # Caught here, before the gate spends any cost on a doomed landing.
    local touched_file others_file collisions
    touched_file=$(mktemp "${TMPDIR:-/tmp}/cs-touched.XXXXXX")
    others_file=$(mktemp "${TMPDIR:-/tmp}/cs-untracked.XXXXXX")
    git -C "$tmp" diff --name-only "$B" HEAD > "$touched_file"
    git -C "$base_dir" ls-files --others --exclude-standard > "$others_file"
    collisions=""
    if [ -s "$touched_file" ] && [ -s "$others_file" ]; then
        collisions=$(grep -Fxf "$touched_file" "$others_file" 2>/dev/null || true)
    fi
    rm -f "$touched_file" "$others_file"
    if [ -n "$collisions" ]; then
        rmdir "$no_hooks"
        error "Untracked files in $base_dir collide with paths the feature adds; base untouched. Colliding paths:
$collisions
Move or delete these untracked files in $base_dir, then re-run /finish $task"
    fi
    # Submodules after the merge, so the gates see the MERGED gitlinks: a
    # feature that adds or bumps a submodule is otherwise gated against
    # absent or stale contents.
    if [ -f "$tmp/.gitmodules" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" submodule update --init --recursive -q >/dev/null 2>&1 \
            || { rmdir "$no_hooks"; error "submodule update failed in $tmp"; }
    fi
    rmdir "$no_hooks"

    local gate_log
    gate_log=$(mktemp "${TMPDIR:-/tmp}/cs-gate.XXXXXX")
    if ! (cd "$tmp" && "$@") > "$gate_log" 2>&1; then
        cat "$gate_log" >&2
        rm -f "$gate_log"
        error "Gate failed in $tmp (output above); base $base_dir untouched at $B"
    fi
    rm -f "$gate_log"

    # Re-verify the base immediately before landing. --ff-only alone is not
    # the "base unchanged" check: a base reset to an ancestor of B still
    # fast-forwards, and unrelated tracked dirt survives one. The residual
    # window between this check and the merge is the one race left; the
    # mutex keeps cs's own writer (the autosave hook) out of it.
    if [ "$(git -C "$base_dir" rev-parse HEAD)" != "$B" ]; then
        error "Base $base_dir moved during the gates (was $B, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish $task"
    fi
    if _tree_is_dirty "$base_dir" || git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        error "Base $base_dir changed during the gates (uncommitted changes or a merge in progress); commit or abort, then re-run /finish $task"
    fi
    # Fast-forward BEFORE removing the temp: until then the merge commit is
    # reachable only from the temp's detached HEAD.
    local R ff_err ff_status=0
    R=$(git -C "$tmp" rev-parse HEAD)
    ff_err=$(git -C "$base_dir" merge --ff-only "$R" 2>&1 >/dev/null) || ff_status=$?
    if [ "$ff_status" != 0 ]; then
        error "Base $base_dir moved or changed during the gates (was $B); re-run /finish $task
${ff_err:-(no output from git merge --ff-only)}"
    fi
    # The base's landing is the one merge that runs with the project's hooks
    # live — it is the user's checkout, and a post-merge hook is entitled to
    # fire there. One that commits leaves base past the commit cs landed, so
    # read HEAD back and report where the base actually is.
    local landed
    landed=$(git -C "$base_dir" rev-parse HEAD)
    if [ "$landed" != "$R" ]; then
        warn "A post-merge hook moved $base_dir to $landed after landing $R"
    fi
    # Keep _INTEGRATE_TMP until the removal is verified, so the EXIT cleanup
    # still has the path if this removal fails; a leftover temp is reported,
    # never silently forgotten.
    if git -C "$base_dir" worktree remove --force "$tmp" >/dev/null 2>&1; then
        _INTEGRATE_TMP=""
    else
        warn "Temporary worktree $tmp could not be removed; run: git -C \"$base_dir\" worktree remove --force \"$tmp\""
    fi

    _terminate_jsonl "$base_dir/.cs/timeline.jsonl"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "feature-integrated" \
           --arg task "$task" \
           --arg sha "$sha" \
           --arg result "$landed" \
        '{ts: $ts, event: $event, task: $task, sha: $sha, result: $result}' \
        >> "$base_dir/.cs/timeline.jsonl" 2>/dev/null || true
    printf 'integrated %s %s -> %s\n' "$task" "$sha" "$landed"
}

# Append one JSONL file onto another, keeping every record on its own line. A
# process killed mid-write leaves a last line with no newline; a bare `cat >>`
# then splices two records into one, and the tolerant per-line reader
# (`fromjson? // empty` in run_conversations) drops BOTH the splice and the
# record that followed it. Terminating on either side costs one byte and keeps
# the loss at zero.
_append_jsonl() {  # src dst
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    _terminate_jsonl "$dst"
    cat "$src" >> "$dst"
    _terminate_jsonl "$dst"
}

# Fuse session records from a worktree .cs into the base .cs (ignored mode:
# the repo does not track .cs/, so git merge cannot carry these). Applies the
# same semantics the merge drivers give tracked repos: union append for
# timeline/log/narratives, copy-never-overwrite for memory topic files,
# base-wins for MEMORY.md.
fuse_session_records() {
    local src="$1" dst="$2"
    local f base

    _append_jsonl "$src/timeline.jsonl" "$dst/timeline.jsonl"
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

# List a base session's feature worktrees with their merge readiness. Read
# only: this is a query, not a gate, so it exits 0 even when nothing can merge.
run_features() {  # base_name [--porcelain]
    local base_name="$1"
    shift
    local porcelain=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --porcelain) porcelain=1; shift ;;
            *) error "Usage: cs $base_name -features [--porcelain]" ;;
        esac
    done

    local features task record
    features=$(_worktree_features "$base_name")
    [ -n "$features" ] || return 0

    if [ -n "$porcelain" ]; then
        while IFS= read -r task; do
            [ -n "$task" ] || continue
            _feature_readiness "$base_name" "$task"
        done <<< "$features"
        return 0
    fi

    printf '%-24s %-24s %6s  %s\n' "FEATURE" "BRANCH" "AHEAD" "STATE"
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        record=$(_feature_readiness "$base_name" "$task")
        printf '%s\n' "$record" | awk -F'\t' \
            '{ detail = ($10 == "untracked") ? sprintf("%s file%s untracked", $7, ($7 == 1) ? "" : "s") : $10;
               printf "%-24s %-24s %6s  %s\n", $1, $2, $3, detail }'
    done <<< "$features"
}

# Ensure auto memory directory exists and migrate from default location
