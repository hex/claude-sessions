# ABOUTME: launch_claude_code: the resume/name/color-aware claude exec path.
# ABOUTME: The final step of opening any session.

# True when a handoff's YAML frontmatter (line 1 "---" through the next "---")
# carries status: unconsumed. Scoped to the frontmatter so a body that quotes
# the contract line flush-left — the rotate skill's own doc does — never counts.
_handoff_is_unconsumed() {  # handoff_file
    awk '
        NR==1 {
            if ($0 != "---") { rc=1; closed=1; exit }
            next
        }
        !closed && $0 == "---" { rc = (matched ? 0 : 1); closed=1; exit }
        !closed && $0 == "status: unconsumed" { matched=1 }
        END { if (!closed) rc=1; exit rc }
    ' "$1" 2>/dev/null
}

# True when the handoff's parent: UUID appears in this checkout's session log,
# meaning this machine ran the conversation that wrote it. The log is
# machine-local by design, so a co-worker's handoff — and this user's own from a
# second machine — both read as absent. This is provenance for the offer to
# show, not a filter: the pick deliberately still offers a handoff from
# elsewhere, because continuing one on another machine is a working flow.
_handoff_is_local() {  # handoff_file, session_dir
    local log="$2/.cs/local/session.log" parent
    [ -f "$log" ] || return 1
    parent=$(awk '
        NR==1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        /^parent:[[:space:]]*/ {
            sub(/^parent:[[:space:]]*/, "")
            gsub(/[[:space:]\r]+$/, "")
            print; exit
        }
    ' "$1" 2>/dev/null)
    [ -n "$parent" ] || return 1
    # Anchored to the line session-start.sh writes, not a bare substring: the
    # bash-logger appends every command to this same file, so an unanchored
    # match reads a logged `claude --resume <uuid>` as proof this checkout ran
    # that conversation and drops the one warning shown before r.
    grep -Fq "Session started" "$log" 2>/dev/null \
        && grep -E -q "Session started \(.*ID: $parent\)" "$log" 2>/dev/null
}

# The last context usage stamped in this session, 0-100, or nothing.
# cs-statusline keys the stamp by SESSION NAME, not by conversation, so it is
# the newest render from any conversation opened here — usually the one being
# resumed, but not when a second conversation (a teammate, or one opened
# outside cs) rendered more recently. The card words it that way rather than
# claiming more than the file knows. Silent on every unusable shape: the stamp
# only exists where the status line is installed, so the readout is a bonus and
# never a reason to fail a launch. 10# because a stamp like 08 is a hard
# arithmetic error read as octal.
_resume_context_pct() {  # session_dir
    local f="$1/.cs/local/context-pct" v=""
    [ -f "$f" ] || return 0
    v=$(tr -d '[:space:]' < "$f" 2>/dev/null || true)
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    # Assignment, not (( )): the latter returns 1 on a zero value, which under
    # set -e would end the launch on a legitimately empty context window.
    v=$((10#$v))
    [ "$v" -le 100 ] || return 0
    printf '%s' "$v"
}

# Drop a rotation marker the user declined to consume. Armed by the rotate
# skill for a /clear, or by an earlier r, it must not outlive the answer: left
# in place it would be consumed by an unrelated /clear hours later, injecting a
# handoff the user already passed on. Announced, because a silent removal turns
# the /clear route into a no-op the user cannot explain.
#
# Pass the handoff that is still pending AFTER this answer, empty when none is.
# Only then does pointing at r hold: an orphaned marker names a spent handoff,
# the r fallthrough is reached precisely because no handoff was offered, and d
# retires the one it had. Offering r in those cases sends the user back for
# something that no longer exists.
_disarm_rotation_marker() {  # session_dir [surviving_handoff]
    local marker="$1/.cs/local/pending-handoff"
    [ -f "$marker" ] || return 0
    rm -f "$marker" 2>/dev/null || true
    # An explicit if: `[ ... ] && return 0` as the last command returns 1 when
    # the test fails, which set -e reads as this function failing.
    if [ -z "${2:-}" ]; then
        printf "${DIM}Rotation marker disarmed.${NC}\n"
        return 0
    fi
    printf "${DIM}Rotation marker disarmed; the handoff stays pending — answer r, or re-run the rotate skill.${NC}\n"
}

launch_claude_code() {
    local session_name="$1"
    local session_dir="$2"
    local is_new="$3"
    local force="${4:-}"
    local merge_feature="${5:-}"

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
        # An in-app /clear rebinds the recorded UUID while the live process's
        # argv still names its launch UUID, so the UUID test alone goes blind.
        # --name is stable for the process's whole life. The trailing delimiter
        # keeps a name that prefixes another (sym vs sym-comfy-nodes) from
        # matching; the appended newline covers --name being the final argument.
        _ps_out="$_ps_out"$'\n'
        if [[ "$_ps_out" == *"$claude_session_id"* ]] \
            || [[ "$_ps_out" == *"--name $session_name "* ]] \
            || [[ "$_ps_out" == *"--name $session_name"$'\n'* ]]; then
            error "Session $session_name is already running elsewhere (UUID $claude_session_id). Use --force to override."
        fi
    fi

    # Set environment variables
    export CLAUDE_SESSION_NAME="$session_name"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
    # An adopted session's name lives only in the symlink pointing here, which a
    # hook walking up from the directory never sees. Record it on open, so
    # sessions adopted before cs wrote the key get it too. Only for those: an
    # ordinary session IS its directory, and a recorded name there would go
    # stale the moment the directory was renamed — outranking a basename that
    # is still right.
    if [ -L "$SESSIONS_ROOT/$session_name" ]; then
        _set_local_state "$session_dir/.cs/local/state" session_name "$session_name"
    fi
    # Prompt rewriting rides Claude Code's external-editor round-trip: ctrl+g
    # writes the composer buffer to a temp file, runs $EDITOR on it, and replaces
    # the composer with whatever comes back. Capture the real editor first so the
    # shim can hand it every file that is NOT a composer buffer.
    if [ "${CS_REWRITE_DISABLE:-}" != "1" ] && [ -x "$HOOKS_DEPLOY_DIR/prompt-rewriter.sh" ]; then
        export CS_REAL_EDITOR="${CS_REAL_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
        export EDITOR="$HOOKS_DEPLOY_DIR/prompt-rewriter.sh"
        export VISUAL="$EDITOR"
    fi
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
    # The pid this shell hands to claude. Every exec arm below replaces this
    # process image, so the launched claude keeps this pid, and Claude Code
    # stamps CLAUDE_PID with the pid of whichever claude fires a hook. Equality
    # of the two is therefore the test for "this conversation is the one cs
    # launched" — the session's single claude_session_id slot is its to rebind,
    # and no other claude's. Identity has to be the process, not the
    # environment: children inherit every exported variable, so a teammate or a
    # headless `claude -p` carries this value while owning a different pid.
    export CS_LEAD_PID=$$

    # Spawn seed: tasks staged by cs -spawn for this session. Consumed here,
    # after the already-running guard and before any exec arm, so a window
    # that died before launching self-heals on the session's next open. A
    # stale seed (>1h) is set aside, never silently armed days later.
    local spawn_kick=""
    local _seed="$SESSIONS_ROOT/.spawn/$session_name.seed"
    if [ -f "$_seed" ]; then
        local _now _age
        _now=$(date +%s)
        _age=$(( _now - $(_epoch_mtime "$_seed") ))
        if [ "$_age" -gt 3600 ]; then
            mv "$_seed" "$_seed.stale" 2>/dev/null || true
            warn "Stale spawn seed set aside: $_seed.stale (re-run cs -spawn if still wanted)"
        else
            local _spawner="" _line _n=0 _first=1
            while IFS= read -r _line || [ -n "$_line" ]; do
                if [ "$_first" = 1 ]; then _spawner="$_line"; _first=0; continue; fi
                # Skip whitespace-only lines, not merely empty ones: _queue_add
                # trims and then errors on an empty body, which under errexit
                # would abort the whole session launch over a stray space in a
                # hand-edited seed.
                case "$_line" in *[![:space:]]*) : ;; *) continue ;; esac
                _queue_add "$session_dir/.cs/local" "$_line"
                _n=$((_n + 1))
            done < "$_seed"
            if [ "$_n" -gt 0 ]; then
                _queue_set_state "$session_dir/.cs/local" armed
                if [ -n "$_spawner" ]; then
                    printf '%s\n' "$_spawner" > "$session_dir/.cs/local/spawned-by"
                    spawn_kick="Spawned by $_spawner. Your walk-away queue is armed with $_n task(s); begin. Send results with: cs -msg $_spawner -k result \"...\""
                else
                    spawn_kick="Your walk-away queue is armed with $_n task(s); begin."
                fi
            fi
            rm -f "$_seed"
        fi
    fi
    # Arming the ritual is an explicit action the user took seconds ago, so it
    # outranks a spawn seed staged earlier. The queue is already armed by this
    # point, so nothing is lost — but the drain is the Stop hook, which fires
    # at the first turn end, so do not promise it runs after the merge.
    local merge_kick=""
    [ -n "$merge_feature" ] && merge_kick="/merge $merge_feature"
    if [ -n "$merge_kick" ] && [ -n "$spawn_kick" ]; then
        warn "A walk-away queue is armed here; it will begin at the first turn end."
    fi
    # The kick prompt takes claude's single positional-prompt slot, displacing
    # the /color re-apply for this one launch (color returns next open).
    local launch_prompt="${merge_kick:-${spawn_kick:-$color_arg}}"

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
        # cs records only the conversation it launched, so one started any other
        # way on this folder — a `/desktop` handoff, a claude opened on the
        # directory — leaves the recorded uuid naming an older conversation.
        # That uuid still resolves, so `--resume` SUCCEEDS and the quick-failure
        # fallback below never fires: the launch would continue a superseded
        # prefix with nothing said. Name the newer one rather than switching to
        # it, which would hand the session to whatever was last opened here.
        if [ -n "$claude_session_id" ]; then
            local _proj _newest
            _proj=$(_claude_project_dir "$session_dir")
            # Only when the recorded conversation is real. A recorded uuid with
            # no transcript is the orphan case migrate_session already repairs,
            # and reporting the repair target as a rival would be nonsense.
            if [ -f "$_proj/$claude_session_id.jsonl" ]; then
                _newest=$(_discover_session_uuid_in "$_proj")
                # "Newer" is a claim about the clock, so check it rather than
                # infer it from "discovery returned something else". Discovery
                # skips teammates, so when the recorded slot is itself a
                # teammate's — the state this gate exists to stop — what comes
                # back is genuinely OLDER, and announcing it as newer would be
                # a lie built on a correct skip.
                if [ -n "$_newest" ] && [ "$_newest" != "$claude_session_id" ] \
                    && [ "$_proj/$_newest.jsonl" -nt "$_proj/$claude_session_id.jsonl" ]; then
                    printf "${DIM}A newer conversation was opened here outside cs:${NC} %s\n" "$_newest"
                    printf "${DIM}Resuming the recorded one instead. To continue the newer:${NC} claude --resume %s\n" "$_newest"
                fi
            fi
        fi

        # Deliberate rotation: an unconsumed handoff written by the rotate
        # skill adds a third answer. Lexicographically last basename wins
        # (the YYYY-MM-DD- prefix makes that the newest date).
        local pending_handoff="" _hf
        for _hf in "$session_dir/.cs/handoffs"/*.md; do
            [ -f "$_hf" ] || continue
            _handoff_is_unconsumed "$_hf" || continue
            pending_handoff="$_hf"
        done
        # .cs/handoffs/ is shared and nothing ever deletes a handoff, so a file
        # belonging to another checkout keeps status: unconsumed indefinitely —
        # the rotate skill will not supersede one whose parent is absent from
        # this machine's session.log, and correctly so. Sorting last, it would
        # shadow the handoff this machine armed and r would rotate into someone
        # else's plan. An armed marker is an explicit choice, so it outranks the
        # scan; a marker naming a spent or absent file is stale and the scan
        # still answers. The marker names a basename, never a path: a separator
        # would resolve outside the handoff store.
        local _marker="$session_dir/.cs/local/pending-handoff" _armed
        if [ -f "$_marker" ]; then
            _armed=$(cat "$_marker" 2>/dev/null | tr -d '[:space:]' || true)
            case "$_armed" in */*|*\\*) _armed="" ;; esac
            if [ -n "$_armed" ] && [ -f "$session_dir/.cs/handoffs/$_armed" ] \
                && _handoff_is_unconsumed "$session_dir/.cs/handoffs/$_armed"; then
                pending_handoff="$session_dir/.cs/handoffs/$_armed"
            fi
        fi
        # A spawned launch is unattended: take the default (resume) instead
        # of parking the tmux window on an interactive ask.
        if [ -n "$spawn_kick" ]; then
            response=""
        else
            # What the answer costs: continuing a conversation already deep into
            # its window is the case the r answer exists for, and the card was
            # asking without saying which case this is.
            local _ctx=""
            _ctx=$(_resume_context_pct "$session_dir")
            if [ -n "$_ctx" ]; then
                printf "${DIM}Last conversation here used %s%% of its context.${NC}\n" "$_ctx"
            fi
            if [ -n "$pending_handoff" ]; then
                # Answering blind is the hazard this label exists for: r arms
                # the marker with this basename, and the next SessionStart flips
                # that file to consumed under this machine's UUID — on a
                # colleague's live rotation, that is their artifact being taken.
                local _origin=""
                _handoff_is_local "$pending_handoff" "$session_dir" \
                    || _origin=" ${DIM}(from another checkout)${NC}"
                printf "${DIM}Rotation handoff pending:${NC} %s%s\n" "$(basename "$pending_handoff")" "$_origin"
                printf "${DIM}Continue previous conversation?${NC} [Y/n/r/d] ${DIM}(r = fresh conversation with handoff, d = discard handoff)${NC} "
            else
                printf "${DIM}Continue previous conversation?${NC} [Y/n] "
            fi
            # Single keypress, no Enter needed (mirrors the collision menu).
            # ESC or EOF (piped close) cancels the launch; Enter takes the
            # default (resume) via the case's *) arm below.
            IFS= read -rsn1 response || { echo; exit 130; }
            echo
            case "$response" in $'\e') exit 130 ;; esac
        fi
        case "$response" in
            [nN]|[nN][oO])
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                continue_flag=""
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    mkdir -p "$session_dir/.cs/local"
                    printf '%s\n' "$(basename "$pending_handoff")" > "$session_dir/.cs/local/pending-handoff"
                    echo ""
                    # r is the user explicitly choosing the rotation handoff
                    # over resuming; a merge armed moments earlier must not
                    # silently override the choice they just made.
                    if [ -n "$merge_kick" ]; then
                        warn "Rotation handoff takes this launch; re-run: cs $session_name -finish $merge_feature"
                    fi
                    _exec_fresh_rebind "$session_dir" handoff "$(basename "$pending_handoff")" "$spawn_kick" ""
                fi
                # r without a pending handoff was never offered: treat as the
                # default resume answer, disarm included.
                _disarm_rotation_marker "$session_dir"
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
            [dD])
                # Nothing survives d: it retires the handoff it was offered, and
                # an orphaned marker had none to begin with.
                _disarm_rotation_marker "$session_dir"
                if [ -n "$pending_handoff" ]; then
                    # Flip only the first status line (the frontmatter's); a
                    # body quoting the contract line flush-left stays intact.
                    awk '
                        !flipped && $0 == "status: unconsumed" {
                            print "status: discarded"
                            flipped = 1
                            next
                        }
                        { print }
                    ' "$pending_handoff" > "$pending_handoff.tmp" 2>/dev/null \
                        && mv "$pending_handoff.tmp" "$pending_handoff" 2>/dev/null \
                        || rm -f "$pending_handoff.tmp" 2>/dev/null || true
                    printf "${DIM}Handoff discarded:${NC} %s\n" "$(basename "$pending_handoff")"
                fi
                # d without a pending handoff was never offered: treat as the
                # default resume answer.
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
            *)
                # Also the unattended spawn path, which takes this default
                # without asking.
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
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
        $CLAUDE_CODE_BIN --name "$session_name" $continue_flag ${launch_prompt:+"$launch_prompt"} || rc=$?
        if [ $rc -ne 0 ] && [ $SECONDS -lt 3 ]; then
            # Quick failure suggests no conversation to continue. Rebind so
            # the fresh transcript claude is about to create is tracked by
            # cs (otherwise the recorded claude_session_id keeps pointing at
            # a transcript that doesn't resolve, and the next launch repeats
            # the same failure).
            echo -e "${DIM}No previous conversation found. Starting fresh...${NC}"
            echo ""
            _exec_fresh_rebind "$session_dir" resume-failed "" "$spawn_kick" "$merge_kick"
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
            exec $CLAUDE_CODE_BIN --name "$session_name" --session-id "$claude_session_id" ${launch_prompt:+"$launch_prompt"}
        elif [ "$is_new" = "false" ]; then
            _exec_fresh_rebind "$session_dir" declined-resume "" "$spawn_kick" "$merge_kick"
        else
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$session_name" ${launch_prompt:+"$launch_prompt"}
        fi
    fi
}

# Run secrets subcommand
