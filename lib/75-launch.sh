# ABOUTME: launch_claude_code: the resume/name/color-aware claude exec path.
# ABOUTME: The final step of opening any session.

launch_claude_code() {
    local session_name="$1"
    local session_dir="$2"
    local is_new="$3"
    local force="${4:-}"

    # Terminal theme (and its real background RGB when known) for the statusline
    # and hooks, detected while cs still owns the tty and reused by the session
    # launched next.
    _export_term_theme
    # Refresh the palette now that the theme is known so everything below —
    # the collision menu and the launch banner — reads on a light canvas
    # (colors were first set at startup, defaulting to dark).
    setup_palette

    # Acquire session lock before anything else
    acquire_session_lock "$session_dir/.cs" "$force" "$session_name"
    # A force chosen at the collision menu is equivalent to --force for the
    # rest of the launch.
    [ "${CS_COLLISION_FORCE:-}" = "1" ] && force="true"
    trap 'reset_tab_title; release_session_lock "'"$session_dir/.cs"'"' EXIT
    trap 'reset_tab_title; release_session_lock "'"$session_dir/.cs"'"; exit 130' INT TERM

    # Opening an archived session revives it. Placed after lock acquisition so
    # a cancelled collision menu leaves the marker in place; the removal is
    # left uncommitted, like every cs edit to session content.
    if [ -f "$session_dir/.cs/archived" ]; then
        rm -f "$session_dir/.cs/archived"
        info "Unarchived: $session_name"
    fi

    # Read the session's recorded UUID (allocated by create_session_structure
    # on new sessions or backfilled by migrate_session Phase 8 on legacy ones).
    # Used for both the CS_CLAUDE_SESSION_ID env export below and for the
    # spawn args at exec time. Empty only if the state file is somehow
    # missing — exec paths fall back gracefully.
    local claude_session_id claude_session_color
    claude_session_id=$(_read_local_state "$session_dir/.cs/local/state" claude_session_id)
    claude_session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)

    # Build the trailing positional prompt arg that applies the session's
    # color at launch. Claude has no --color CLI flag (verified through
    # 2.1.162); the slash command as a positional prompt is the only
    # mechanism. Slash commands at launch produce no transcript entry —
    # confirmed by grep against this session's own jsonl after a /color
    # invocation — so re-applying every launch is free.
    local color_arg=""
    [ -n "$claude_session_color" ] && color_arg="/color $claude_session_color"

    # Live-duplicate guard: refuse to spawn a second claude process for the
    # same session UUID. Mostly catches "I opened this in two tabs" accidents.
    # --force overrides. Tests stub `ps` via CS_PS_BIN to inject canned output;
    # production runs the real `ps`. Best-effort — ps failures fall through.
    #
    # The match uses a bash builtin (`[[ ... == *needle* ]]`) rather than
    # piping ps to grep, to avoid the classic grep-finds-itself bug: with
    # `ps -Ao args= | grep -F -- "$UUID"`, grep's own argv contains the
    # UUID and ps sees it, producing a false-positive self-match. The
    # builtin substring test runs entirely in-process and never exposes
    # the UUID as a subprocess argv.
    #
    # Skip when is_new=true: the UUID was just allocated by
    # create_session_structure milliseconds ago, so no other process can
    # be holding it. Spares the ps fork on fresh-spawn.
    if [ -n "$claude_session_id" ] && [ "$force" != "true" ] && [ "$is_new" != "true" ]; then
        local _ps_out
        _ps_out=$("${CS_PS_BIN:-ps}" -Ao args= 2>/dev/null || true)
        if [[ "$_ps_out" == *"$claude_session_id"* ]]; then
            error "Session $session_name is already running elsewhere (UUID $claude_session_id). Use --force to override."
        fi
    fi

    # Set environment variables
    export CLAUDE_SESSION_NAME="$session_name"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
    # Worktree sessions coordinate through the base session's task list and
    # keychain namespace; cs_base is only set in worktree local state.
    local cs_base
    cs_base=$(_read_local_state "$session_dir/.cs/local/state" cs_base)
    export CLAUDE_CODE_TASK_LIST_ID="${cs_base:-$session_name}"
    if [ -n "$cs_base" ]; then
        export CS_SECRETS_SESSION="$cs_base"
    fi
    # Export both names defensively: Claude Code's auto-memory resolver reads
    # CLAUDE_COWORK_MEMORY_PATH_OVERRIDE; the older CLAUDE_CODE_AUTO_MEMORY_PATH
    # is kept in case other Claude Code versions honor it instead.
    local memory_path="$session_dir/.cs/memory"
    export CLAUDE_CODE_AUTO_MEMORY_PATH="$memory_path"
    export CLAUDE_COWORK_MEMORY_PATH_OVERRIDE="$memory_path"
    # Expose the recorded session UUID to hooks. Hooks can use this to
    # reverse-look-up which cs session they're firing inside without having
    # to depend on $CLAUDE_CODE_SESSION_ID (set by Claude Code itself, but
    # only in-session) or walk the filesystem.
    if [ -n "$claude_session_id" ]; then
        export CS_CLAUDE_SESSION_ID="$claude_session_id"
    fi
    # Status indicator
    local status_icon status_text
    if [ "$is_new" = "true" ]; then
        status_icon="+"
        status_text="new"
    else
        status_icon="↻"
        status_text="resuming"
    fi

    # Count secrets for this session
    local secret_count=0
    if command -v cs-secrets >/dev/null 2>&1; then
        secret_count=$(cs-secrets list 2>/dev/null | grep -c "^  - " 2>/dev/null) || secret_count=0
        # Ensure it's a valid integer
        [[ "$secret_count" =~ ^[0-9]+$ ]] || secret_count=0
    fi

    # Display banner with gradient bar (rust → amber)
    # Gradient colors for left bar
    local BAR1='\033[38;2;230;74;25m▌'    # rust #e64a19
    local BAR2='\033[38;2;245;124;0m▌'    # dark orange #f57c00
    local BAR3='\033[38;2;255;152;0m▌'    # orange #ff9800
    local BAR4='\033[38;2;255;179;0m▌'    # amber #ffb300

    local bar_idx=0
    local bars=("$BAR1" "$BAR2" "$BAR3" "$BAR4")

    echo ""
    echo -e "${bars[$bar_idx]}${NC} ${ORANGE}cs${NC} ${GREEN}$VERSION${NC}"; ((++bar_idx))
    echo -e "${bars[$bar_idx]}${NC} ${WHITE}${BOLD}$session_name${NC} ${COMMENT}($status_icon $status_text)${NC} ${DIM}${ICON_HOST} $(hostname -s)${NC}"; ((++bar_idx))
    echo -e "${bars[$bar_idx]}${NC} ${GOLD}$session_dir${NC}"; ((++bar_idx))
    if [ "$secret_count" -gt 0 ]; then
        local secret_word="secret"
        [ "$secret_count" -gt 1 ] && secret_word="secrets"
        echo -e "${bars[$bar_idx]}${NC} ${COMMENT}${ICON_LOCK}${NC} ${YELLOW}$secret_count${NC} ${COMMENT}$secret_word${NC}"; ((++bar_idx))
    fi

    if [ -n "$UPDATE_AVAILABLE" ]; then
        echo -e "${YELLOW}▌${NC} ${YELLOW}Update available:${NC} $VERSION ${COMMENT}→${NC} ${GREEN}$UPDATE_AVAILABLE${NC} ${COMMENT}(cs -update)${NC}"
        local notes_cache="$HOME/.cache/cs/update-notes-$UPDATE_AVAILABLE"
        if [ -s "$notes_cache" ]; then
            local card_w nver nsum
            card_w=$(tput cols 2>/dev/null) || card_w=80
            case "$card_w" in ''|*[!0-9]*) card_w=80 ;; esac
            while IFS=$'\t' read -r nver nsum; do
                if [ "$nver" = "+" ]; then
                    echo -e "${YELLOW}▌${NC}   ${COMMENT}${nsum}${NC}"
                elif [ -n "$nsum" ]; then
                    nsum=$(printf '%.*s' $((card_w - ${#nver} - 6)) "$nsum")
                    echo -e "${YELLOW}▌${NC}   ${GREEN}${nver}${NC} ${COMMENT}${nsum}${NC}"
                fi
            done < "$notes_cache"
        fi
    fi
    echo ""

    # Set terminal tab title and color. The tab color is the session's
    # claude_session_color (same RGB as the statusline block); fall back to a
    # name hash only if no color is recorded.
    local _tab_color
    _tab_color=$(_session_color_rgb "$claude_session_color")
    set_tab_title "cs: $session_name" "${_tab_color:-auto:$session_name}"

    cd "$session_dir"

    # For existing sessions, ask if user wants to continue previous conversation
    local continue_flag=""
    if [ "$is_new" = "false" ]; then
        # Deliberate rotation: an unconsumed handoff written by the rotate
        # skill adds a third answer. Lexicographically last basename wins
        # (the YYYY-MM-DD- prefix makes that the newest date).
        local pending_handoff="" _hf
        for _hf in "$session_dir/.cs/handoffs"/*.md; do
            [ -f "$_hf" ] || continue
            # Scope the scan to the YAML frontmatter (line 1 "---" through the
            # next "---"): a body that quotes the contract line flush-left
            # (the rotate skill's own doc does) must not count as a match.
            awk '
                NR==1 {
                    if ($0 != "---") { rc=1; closed=1; exit }
                    next
                }
                !closed && $0 == "---" { rc = (matched ? 0 : 1); closed=1; exit }
                !closed && $0 == "status: unconsumed" { matched=1 }
                END { if (!closed) rc=1; exit rc }
            ' "$_hf" 2>/dev/null || continue
            pending_handoff="$_hf"
        done
        if [ -n "$pending_handoff" ]; then
            printf "${DIM}Rotation handoff pending:${NC} %s\n" "$(basename "$pending_handoff")"
            printf "${DIM}Continue previous conversation?${NC} [Y/n/r] ${DIM}(r = fresh conversation with handoff)${NC} "
        else
            printf "${DIM}Continue previous conversation?${NC} [Y/n] "
        fi
        read -r response || exit 130
        case "$response" in
            [nN]|[nN][oO])
                continue_flag=""
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    mkdir -p "$session_dir/.cs/local"
                    printf '%s\n' "$(basename "$pending_handoff")" > "$session_dir/.cs/local/pending-handoff"
                    echo ""
                    _exec_fresh_rebind "$session_dir" handoff "$(basename "$pending_handoff")"
                fi
                # r without a pending handoff was never offered: treat as the
                # default resume answer.
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
            *)
                # Prefer --resume <uuid> when the session has a recorded UUID:
                # it names the exact conversation, vs --continue which means
                # "most recent" and may resolve to a sibling Claude session
                # the user ran in a different terminal between cs launches.
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
        esac
        echo ""
    fi

    if [ -n "$continue_flag" ]; then
        # Try continuing previous conversation
        SECONDS=0
        local rc=0
        # shellcheck disable=SC2086
        $CLAUDE_CODE_BIN --name "$session_name" $continue_flag ${color_arg:+"$color_arg"} || rc=$?
        if [ $rc -ne 0 ] && [ $SECONDS -lt 3 ]; then
            # Quick failure suggests no conversation to continue. Rebind so
            # the fresh transcript claude is about to create is tracked by
            # cs (otherwise the recorded claude_session_id keeps pointing at
            # a transcript that doesn't resolve, and the next launch repeats
            # the same failure).
            echo -e "${DIM}No previous conversation found. Starting fresh...${NC}"
            echo ""
            _exec_fresh_rebind "$session_dir" resume-failed
        fi
        exit $rc
    else
        # Fresh-spawn path. Three sub-cases:
        #   - is_new=true: pass --session-id <pre-allocated-uuid> so claude
        #     adopts the UUID create_session_structure wrote into README.
        #   - is_new=false (user said N to resume): rebind to a fresh UUID
        #     and pass --session-id <new> so cs stays bound to the new
        #     conversation. Without rebind, next launch resumes the OLD
        #     conversation while the fresh one becomes orphaned.
        #   - is_new=false with no claude_session_id (shouldn't happen
        #     post-Phase-8 but handled defensively): naked exec.
        if [ "$is_new" = "true" ] && [ -n "$claude_session_id" ]; then
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$session_name" --session-id "$claude_session_id" ${color_arg:+"$color_arg"}
        elif [ "$is_new" = "false" ]; then
            _exec_fresh_rebind "$session_dir" declined-resume
        else
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$session_name" ${color_arg:+"$color_arg"}
        fi
    fi
}

# Run secrets subcommand
