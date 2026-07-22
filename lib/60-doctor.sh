# ABOUTME: Health checks for keychain, hooks, shadow ref, memory, statusline, and tokens.
# ABOUTME: Backs 'cs -doctor' / 'cs -diag'.

_doctor_ok()   { printf "  ${GREEN}[ OK ]${NC} %s\n" "$1"; }
_doctor_warn() { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
_doctor_fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); }

_doctor_check_keychain() {
    local script
    if ! script=$(find_secrets_script); then
        _doctor_warn "Keychain: cs-secrets binary not found on PATH"
        return
    fi
    local backend_line
    backend_line=$("$script" backend 2>/dev/null | grep '^Storage backend:' | head -1 || true)
    if [ -z "$backend_line" ]; then
        _doctor_fail "Keychain: cs-secrets backend check failed"
        return
    fi
    _doctor_ok "Keychain: ${backend_line#Storage backend: }"
}

_doctor_check_hooks_registered() {
    local hooks_dir="$HOOKS_DEPLOY_DIR"
    local settings="${CS_CLAUDE_DIR:-$HOME/.claude}/settings.json"
    if [ ! -f "$settings" ]; then
        _doctor_warn "Hooks: $settings not found (cs may not be installed via install.sh)"
        return
    fi
    if [ ! -d "$hooks_dir" ]; then
        _doctor_warn "Hooks: directory $hooks_dir not found"
        return
    fi
    local names settings_contents missing=()
    names=$(cd "$hooks_dir" && ls *.sh 2>/dev/null || true)
    [ -z "$names" ] && { _doctor_warn "Hooks: no .sh files in $hooks_dir"; return; }
    settings_contents=$(cat "$settings")
    local name
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$settings_contents" in
            *"/$name"*) ;;
            *) missing+=("$name") ;;
        esac
    done <<< "$names"
    if [ ${#missing[@]} -eq 0 ]; then
        _doctor_ok "Hooks: all registered in settings.json"
    else
        _doctor_fail "Hooks: missing in settings.json: ${missing[*]}"
    fi
}

_doctor_check_hook_files_executable() {
    local hooks_dir="$HOOKS_DEPLOY_DIR"
    if [ ! -d "$hooks_dir" ]; then
        _doctor_warn "Hooks: directory $hooks_dir not found"
        return
    fi
    local non_exec=()
    local f
    for f in "$hooks_dir"/*.sh; do
        [ -e "$f" ] || continue
        if [ ! -x "$f" ]; then
            non_exec+=("$(basename "$f")")
        fi
    done
    if [ ${#non_exec[@]} -eq 0 ]; then
        _doctor_ok "Hooks: all files executable"
    else
        _doctor_fail "Hooks: not executable: ${non_exec[*]}"
    fi
}

# Compares deployable artifacts in the current directory's cs source checkout
# (hooks/*.sh, commands/*.md, skills/*/SKILL.md) against their deployed
# copies. A source edit only takes effect once install.sh deploys it, so
# silent drift between the two means the running install doesn't match what
# the source says it does. Silent outside a checkout.
_doctor_check_hook_drift() {
    local hooks_dir="$HOOKS_DEPLOY_DIR"
    local commands_dir="${CS_COMMANDS_DIR:-$HOME/.claude/commands}"
    local skills_dir="${CS_SKILLS_DIR:-$HOME/.claude/skills}"
    [ -d "hooks" ] && [ -f "install.sh" ] && [ -f "bin/cs" ] || return 0

    local clean=1

    # area label, deploy root, source paths — reported per artifact kind.
    # Skills deploy as <name>/SKILL.md; everything else deploys flat, keyed
    # on the source path shape so the label stays purely cosmetic.
    _drift_scan() {
        local label="$1" deploy_root="$2"
        shift 2
        local drifted=() missing=() src name deployed
        for src in "$@"; do
            [ -e "$src" ] || continue
            if [[ "$src" == */SKILL.md ]]; then
                name=$(basename "$(dirname "$src")")
                deployed="$deploy_root/$name/SKILL.md"
            elif [[ "$src" == skills/*/scripts/* ]]; then
                name="${src#skills/}"
                deployed="$deploy_root/$name"
            else
                name=$(basename "$src")
                deployed="$deploy_root/$name"
            fi
            if [ ! -f "$deployed" ]; then
                missing+=("$name")
            elif ! cmp -s "$src" "$deployed"; then
                drifted+=("$name")
            fi
        done
        if [ ${#drifted[@]} -gt 0 ]; then
            _doctor_warn "$label drift: deployed copy differs from source: ${drifted[*]} (run ./install.sh)"
            clean=0
        fi
        if [ ${#missing[@]} -gt 0 ]; then
            _doctor_warn "$label drift: not deployed: ${missing[*]} (run ./install.sh)"
            clean=0
        fi
    }

    _drift_scan "Hook" "$hooks_dir" hooks/*.sh
    _drift_scan "Command" "$commands_dir" commands/*.md
    _drift_scan "Skill" "$skills_dir" skills/*/SKILL.md skills/*/scripts/*.sh

    if [ "$clean" = "1" ]; then
        _doctor_ok "Deploy drift: hooks, commands, and skills match checkout source"
    fi
}

# iTerm2 awareness, reported only when running inside iTerm2: tab color and
# title ship via native escapes regardless; the attention dock bounce needs
# the it2 utilities from iTerm2 shell integration (~/.iterm2, not on PATH).
_doctor_check_iterm2() {
    [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || return 0
    if [ -n "${CS_NO_ITERM2:-}" ]; then
        _doctor_ok "iTerm2: integrations disabled (CS_NO_ITERM2)"
    elif [ -x "${CS_IT2_DIR:-$HOME/.iterm2}/it2attention" ]; then
        _doctor_ok "iTerm2: tab color + attention bounce active (it2 utilities found)"
    else
        _doctor_ok "iTerm2: tab color active; attention bounce off (shell integration not installed)"
    fi
}

# Spawn hygiene, all best-effort warnings:
#   - .seed.stale files accumulate in .spawn/ (the launch path sets aged-out
#     seeds aside but never deletes them),
#   - a pending .seed for a session that does not exist blocks re-spawning
#     that name until it is removed,
#   - a spawned-by pointer at a deleted session sends the drain notify nowhere,
#   - a tmux session named 'cs' without the @cs_managed stamp is one cs -spawn
#     will refuse to reuse.
_doctor_check_spawn() {
    local spawn_dir="$SESSIONS_ROOT/.spawn"
    local stale=() orphan=() dangling=() clean=1
    local f name

    if [ -d "$spawn_dir" ]; then
        for f in "$spawn_dir"/*.seed.stale; do
            [ -e "$f" ] || continue
            stale+=("$(basename "$f")")
        done
        for f in "$spawn_dir"/*.seed; do
            [ -e "$f" ] || continue
            name=$(basename "$f" .seed)
            is_session_dir "$SESSIONS_ROOT/$name" || orphan+=("$name")
        done
    fi
    if [ ${#stale[@]} -gt 0 ]; then
        _doctor_warn "Spawn seeds: ${#stale[@]} aged-out .seed.stale file(s) in .spawn/ (nothing prunes them; safe to delete): ${stale[*]}"
        clean=0
    fi
    if [ ${#orphan[@]} -gt 0 ]; then
        _doctor_warn "Spawn seeds: pending seed(s) with no session: ${orphan[*]} (cs -spawn refuses these names until the seed is removed)"
        clean=0
    fi

    local dir sb spawner
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        sb="$dir/.cs/local/spawned-by"
        [ -s "$sb" ] || continue
        IFS= read -r spawner < "$sb" || true
        spawner=$(printf '%s' "$spawner" | tr -d '[:space:]')
        [ -n "$spawner" ] || continue
        is_session_dir "$SESSIONS_ROOT/$spawner" || dangling+=("$(basename "$dir") -> $spawner")
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | sort -z)
    if [ ${#dangling[@]} -gt 0 ]; then
        _doctor_warn "Spawn links: spawned-by names a missing session: ${dangling[*]} (the drain notify goes nowhere)"
        clean=0
    fi

    if command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 && _tmux has-session -t =cs 2>/dev/null; then
        if ! _cs_tmux_managed; then
            _doctor_warn "tmux: a session named 'cs' exists but is not cs-managed (@cs_managed unset); cs -spawn will refuse to use it"
            clean=0
        fi
    fi

    # An `if` (not `[ ... ] && ...`) so the function returns 0 even when a
    # warning fired: under `set -e` a non-zero return here would abort the
    # whole `cs -doctor` run before its later checks and the summary.
    if [ "$clean" = "1" ]; then
        _doctor_ok "Spawn: no stale seeds, dangling spawned-by links, or foreign 'cs' tmux session"
    fi
}

# Compares the version stamped into the deployed hooks directory at install
# time against this binary's VERSION. A mismatch means cs was updated without
# re-deploying its artifacts (or vice versa). Skips silently when no stamp
# exists.
_doctor_check_deployed_version() {
    local stamp="$HOOKS_DEPLOY_DIR/.version"
    [ -f "$stamp" ] || return 0
    local deployed
    deployed=$(cat "$stamp" 2>/dev/null || true)
    [ -n "$deployed" ] || return 0
    if [ "$deployed" = "$VERSION" ]; then
        _doctor_ok "Deployed version: artifacts stamped $deployed match cs $VERSION"
    else
        _doctor_warn "Deployed version: artifacts stamped $deployed but cs is $VERSION (run install.sh)"
    fi
}

# Inverse of _doctor_check_hooks_registered: walks every hook command in
# settings.json and warns when its `command` path doesn't exist on disk.
# Catches orphans left behind by feature branches that registered a hook
# without ever shipping the corresponding file.
_doctor_check_settings_hooks_resolve() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    if [ ! -f "$settings" ]; then
        return
    fi
    local commands
    commands=$(jq -r '.hooks // {} | to_entries[].value[].hooks[]?.command // empty' "$settings" 2>/dev/null)
    # Native jq.exe on Windows emits CRLF; strip the trailing \r so hook paths
    # aren't tested as "/path\r" (which never exists) and mis-reported missing.
    commands=${commands//$'\r'/}
    if [ -z "$commands" ]; then
        _doctor_ok "Hook paths: no hooks registered in settings.json"
        return
    fi
    local missing=() cmd resolved
    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        resolved="${cmd/#~/$HOME}"
        resolved="${resolved%% *}"
        # Only validate commands that reference a script by absolute path. Inline
        # shell snippets (e.g. `if [ -z "$TMUX" ]; then ...`) and wrapped commands
        # (`bash ...`) are valid hooks, not file paths — skip them so they are not
        # mis-reported as missing files.
        case "$resolved" in
            /*) ;;
            *) continue ;;
        esac
        if [ ! -f "$resolved" ]; then
            missing+=("$(basename "$resolved")")
        fi
    done <<< "$commands"
    if [ ${#missing[@]} -eq 0 ]; then
        _doctor_ok "Hook paths: all registered hooks resolve to existing files"
    else
        _doctor_warn "Hook paths: ${#missing[@]} registered hook(s) point at missing files: ${missing[*]}"
    fi
}

_doctor_check_worktrees() {
    local root="$SESSIONS_ROOT"
    local d name base_name base_dir d_real pinned head_branch
    for d in "$root"/*@*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        base_name="${name%%@*}"
        base_dir=$(_resolve_session_dir "$base_name")
        if [ ! -d "$base_dir" ]; then
            _doctor_warn "Worktrees: $name has no base session '$base_name'"
            continue
        fi
        d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
        if ! git -C "$base_dir" worktree list --porcelain 2>/dev/null \
            | grep -qx "worktree $d_real"; then
            _doctor_warn "Worktrees: $name is not a registered worktree of $base_name (pruned or created by hand?)"
            continue
        fi
        pinned=$(_read_local_state "$d/.cs/local/state" task_branch)
        head_branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "")
        if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
            _doctor_warn "Worktrees: $name HEAD is '$head_branch', expected '$pinned'"
            continue
        fi
        # "Fully merged" needs the tip strictly behind base HEAD: a fresh
        # worktree's branch sits AT base HEAD, where is-ancestor is also true.
        if [ -n "$pinned" ] \
            && git -C "$base_dir" merge-base --is-ancestor "$pinned" HEAD 2>/dev/null \
            && [ "$(git -C "$base_dir" rev-parse "$pinned" 2>/dev/null)" != "$(git -C "$base_dir" rev-parse HEAD 2>/dev/null)" ]; then
            _doctor_warn "Worktrees: $name branch $pinned is fully merged; finish with: cs $base_name --merge ${name#*@}"
        else
            _doctor_ok "Worktrees: $name on ${head_branch:-<detached>}"
        fi
    done
}

_doctor_check_shadow_ref() {
    local dir="${CLAUDE_SESSION_DIR:-$PWD}"
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        _doctor_warn "Shadow ref: session directory is not a git repo"
        return
    fi
    local shadow_sha
    shadow_sha=$(git -C "$dir" show-ref --verify refs/worktree/cs/auto 2>/dev/null | awk '{print $1}' || true)
    local has_changes=0
    git -C "$dir" diff --quiet HEAD 2>/dev/null || has_changes=1
    if [ "$has_changes" = "1" ] && [ -z "$shadow_sha" ]; then
        _doctor_warn "Shadow ref: uncommitted changes but no refs/worktree/cs/auto (autosave may be broken)"
    elif [ -n "$shadow_sha" ]; then
        local ts now age
        ts=$(git -C "$dir" log -1 --format=%ct "$shadow_sha" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - ts))
        _doctor_ok "Shadow ref: refs/worktree/cs/auto present (${age}s old)"
    else
        _doctor_ok "Shadow ref: no uncommitted work to snapshot"
    fi
}

_doctor_check_claude_audit() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    if [ ! -f "$settings" ]; then
        _doctor_warn "Audit: $settings not found"
        return
    fi
    # .hooks is event -> [{matcher, hooks: [{type, command, ...}]}]; flatten 3 levels for command count.
    local counts hooks_count mcps_count perms_count env_count
    counts=$(jq -r '
        "\([.hooks // {} | to_entries[].value[].hooks[]?] | length) " +
        "\(.mcpServers // {} | length) " +
        "\(((.permissions.allow // []) + (.permissions.deny // [])) | length) " +
        "\(.env // {} | length)"
    ' "$settings" 2>/dev/null || echo "0 0 0 0")
    read -r hooks_count mcps_count perms_count env_count <<< "$counts"
    _doctor_ok "Audit: ${hooks_count} hooks, ${mcps_count} MCPs, ${perms_count} perm rules, ${env_count} env vars in settings.json"
}

_doctor_check_statusline() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    local cmd=""
    if [ -f "$settings" ]; then
        cmd=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null) || cmd=""
    fi
    if [ -z "$cmd" ]; then
        _doctor_ok "Statusline: not registered (optional; enable with: cs -statusline enable)"
        return
    fi
    case "$cmd" in
        */cs-statusline)
            local bin="${cmd/#\~/$HOME}"
            if [ -x "$bin" ]; then
                _doctor_ok "Statusline: cs-statusline registered and executable"
            else
                _doctor_fail "Statusline: registered as $cmd but the binary is missing or not executable"
            fi
            ;;
        *)
            _doctor_ok "Statusline: using a non-cs status line ($cmd)"
            ;;
    esac
}

_doctor_check_subagent_statusline() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    local cmd=""
    if [ -f "$settings" ]; then
        cmd=$(jq -r '.subagentStatusLine.command // ""' "$settings" 2>/dev/null) || cmd=""
    fi
    if [ -z "$cmd" ]; then
        _doctor_ok "Subagent statusline: not registered (optional; enable with: cs -statusline enable)"
        return
    fi
    case "$cmd" in
        */cs-subagent-statusline)
            local bin="${cmd/#\~/$HOME}"
            if [ -x "$bin" ]; then
                _doctor_ok "Subagent statusline: cs-subagent-statusline registered and executable"
            else
                _doctor_fail "Subagent statusline: registered as $cmd but the binary is missing or not executable"
            fi
            ;;
        *)
            _doctor_ok "Subagent statusline: using a non-cs row renderer ($cmd)"
            ;;
    esac
}

_doctor_check_token_cost() {
    local proj_dir
    proj_dir=$(_claude_project_dir "${CLAUDE_SESSION_DIR:-$PWD}")

    local files=("$proj_dir"/*.jsonl)
    if [ ! -e "${files[0]:-}" ]; then
        _doctor_ok "Tokens (this project): no transcripts found yet"
        return
    fi
    local sums in_l out_l
    sums=$(_usage_scan "" "" "${files[@]}")
    in_l=$(printf '%s' "$sums" | awk '{print $7}')
    out_l=$(printf '%s' "$sums" | awk '{print $9}')
    _doctor_ok "Tokens (this project): $(_usage_fmt "$in_l") input, $(_usage_fmt "$out_l") output"
}

_doctor_check_auto_memory() {
    local dir="$CLAUDE_SESSION_META_DIR/memory"
    if [ ! -d "$dir" ]; then
        _doctor_warn "Auto-memory: $dir does not exist"
        return
    fi
    if [ -w "$dir" ]; then
        _doctor_ok "Auto-memory: $dir writable"
    else
        _doctor_fail "Auto-memory: $dir not writable"
    fi
}

# Cross-check the session UUID recorded in .cs/local/state against
# the live $CLAUDE_CODE_SESSION_ID (set by Claude Code inside its own session).
# A mismatch means the running claude conversation is not the one cs thinks
# it is — usually because the user launched claude outside cs in this dir,
# or because migrate_session backfilled a UUID after Claude Code had already
# resolved its own session ID. The recorded UUID is the source of truth for
# cs and hooks; doctor surfaces the divergence so the user can decide whether
# to relaunch via cs or accept the drift.
_doctor_check_session_id_match() {
    local state="$CLAUDE_SESSION_META_DIR/local/state"
    local recorded
    recorded=$(_read_local_state "$state" claude_session_id)
    if [ -z "$recorded" ]; then
        _doctor_warn "Session UUID: not recorded in .cs/local/state — next cs launch will backfill"
        return
    fi
    local current="${CLAUDE_CODE_SESSION_ID:-}"
    if [ -z "$current" ]; then
        _doctor_ok "Session UUID: $recorded (\$CLAUDE_CODE_SESSION_ID unset, cannot verify)"
        return
    fi
    if [ "$recorded" = "$current" ]; then
        _doctor_ok "Session UUID: $recorded matches \$CLAUDE_CODE_SESSION_ID"
    else
        _doctor_warn "Session UUID mismatch: recorded $recorded, but \$CLAUDE_CODE_SESSION_ID=$current"
    fi
}

run_doctor() {
    local DOCTOR_FAIL=0
    local DOCTOR_WARN=0

    echo "cs doctor - running health checks"
    echo ""

    _doctor_check_keychain
    _doctor_check_hooks_registered
    _doctor_check_hook_files_executable
    _doctor_check_hook_drift
    _doctor_check_deployed_version
    _doctor_check_settings_hooks_resolve
    _doctor_check_claude_audit
    _doctor_check_statusline
    _doctor_check_subagent_statusline
    _doctor_check_iterm2
    _doctor_check_spawn

    if [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -d "${CLAUDE_SESSION_META_DIR:-}" ]; then
        _doctor_check_shadow_ref
        _doctor_check_worktrees
        _doctor_check_auto_memory
        _doctor_check_session_id_match
        _doctor_check_token_cost
    fi

    echo ""
    if [ "$DOCTOR_FAIL" -gt 0 ]; then
        echo -e "${RED}Failed: $DOCTOR_FAIL  Warnings: $DOCTOR_WARN${NC}"
        return 1
    elif [ "$DOCTOR_WARN" -gt 0 ]; then
        echo -e "${YELLOW}Complete with $DOCTOR_WARN warning(s).${NC}"
    else
        echo -e "${GREEN}All checks OK.${NC}"
    fi
    return 0
}

# Search across all sessions' metadata
