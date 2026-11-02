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
    local log parent
    log="$(cs_private_dir "$2/.cs")/session.log" || return 1
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
    # Anchored to the line session-start.sh writes, not a bare substring: this
    # file can hold the `BASH:` command lines the retired bash-logger hook
    # appended, so an unanchored match reads a logged `claude --resume <uuid>`
    # as proof this checkout ran that conversation and drops the one warning
    # shown before r.
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
# The forcing ships on, so a machine that has never been told gets one notice
# at launch and never again. Marker under the config dir, beside the status
# line's caps answer; an unwritable config dir prints the notice every launch
# rather than aborting the launch, which is the harmless half of the trade.
_rotate_force_notice_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/cs/rotate-force-notice"
}

# Mirrors forceThreshold() in mods/cs/hooks/register.tsx: unset is the
# default, `off` (any case) and zero turn it off, 1 to 100 moves it, and
# anything else, a number past 100 included, is the default rather than
# silence. KEEP IN SYNC with that resolver. The variable carries a settings
# file's value too: cs_config_load fills every unpinned key before the launch.
_rotate_force_threshold() {  # -> prints the percentage, or nothing when off
    local raw="${CS_ROTATE_FORCE_CTX-}"
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$raw" ] && { echo 80; return 0; }
    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
        off) return 0 ;;
    esac
    case "$raw" in
        *[!0-9]*) echo 80; return 0 ;;
        *) [ "$((10#$raw))" -eq 0 ] && return 0
           [ "$((10#$raw))" -gt 100 ] && { echo 80; return 0; }
           echo "$((10#$raw))" ;;
    esac
}

_rotate_force_notice() {
    local pct f
    # The mod that forces is a function-hooks plugin: without the loader flag
    # (withheld by CS_NO_FUNCTION_HOOKS, or 0 from the shell) nothing rotates,
    # so there is nothing to announce and the marker must stay unspent.
    case "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-}" in ''|0) return 0 ;; esac
    pct="$(_rotate_force_threshold)"
    [ -n "$pct" ] || return 0
    f="$(_rotate_force_notice_file)"
    [ -f "$f" ] && return 0
    printf '%s\n' "cs now rotates a conversation on its own once it ends a turn past ${pct}% context: it writes a handoff, then counts down 20 seconds to the /clear (press Ctrl+X 1 to go now, type anything to stop it)."
    printf '%s\n' "To turn that off, export CS_ROTATE_FORCE_CTX=off; to move it, set a percentage. Said once per machine."
    mkdir -p "$(dirname "$f")" 2>/dev/null && { printf '%s\n' "notified" > "$f"; } 2>/dev/null || true
}

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
    local marker
    marker="$(cs_private_dir "$1/.cs")/pending-handoff" || return 0
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

# A session whose .cs/claude-config exists keeps Claude Code's whole config
# dir there (transcripts, prompt history, .claude.json and its backups), so an
# encrypted session's conversation never lands in ~/.claude. The login stays
# the one the shell would use: CLAUDE_SECURESTORAGE_CONFIG_DIR names the
# keychain entry independently of the config dir, and empty selects the
# default entry. A value inherited from a parent launch into such a session is
# recognisable by its path and dropped, so a session without the link opens
# on the shell's own config.
_export_session_claude_config() {  # session_dir
    local config="$1/.cs/claude-config"
    case "${CLAUDE_CONFIG_DIR:-}" in
        */.cs/claude-config)
            unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR
            ;;
    esac
    [ -e "$config" ] || return 0
    _link_shared_claude_config "$config" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # Claude Code keeps .claude.json beside the config dir by default, inside it
    # when CLAUDE_CONFIG_DIR is set.
    _seed_session_claude_json "$config" "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    export CLAUDE_SECURESTORAGE_CONFIG_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR-${CLAUDE_CONFIG_DIR-}}"
    export CLAUDE_CONFIG_DIR="$config"
}

# The session's config dir shares the shell's settings, instructions and
# extensions by symlink, so hooks, skills and plugins behave as they do
# anywhere else. Only these names are shared: everything else Claude Code
# writes (projects/, history.jsonl, backups/, todos/) is born in the session's
# config dir and stays behind the vault. An entry already there is the
# session's own and is left alone.
_link_shared_claude_config() {  # session_config_dir, shell_config_dir
    local name
    for name in settings.json settings.local.json CLAUDE.md AGENTS.md rules skills \
        commands agents hooks plugins output-styles keybindings.json vale; do
        [ -e "$2/$name" ] || continue
        [ -e "$1/$name" ] || [ -L "$1/$name" ] && continue
        ln -s "$2/$name" "$1/$name" || error "could not link $1/$name to $2/$name."
    done
}

# The session's .claude.json starts once as a copy of the shell's, so the
# login's onboarding and preferences carry over, with every project's record
# dropped: each keeps that project's last prompt in plaintext. From then on it
# is the session's own. jq exits 0 on an empty file and prints nothing, so -e
# is what turns an empty or unreadable source into a refusal.
_seed_session_claude_json() {  # session_config_dir, shell_claude_json
    local dest="$1/.claude.json" tmp
    [ -e "$dest" ] || [ -L "$dest" ] && return 0
    [ -e "$2" ] || return 0
    tmp=$(mktemp "$1/.claude.json.XXXXXX") || error "could not create a temporary file in $1."
    if ! jq -e '.projects = {}' "$2" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "$2 is not a JSON object cs can copy into $1; fix it, then reopen."
    fi
    mv "$tmp" "$dest" || { rm -f "$tmp"; error "could not write $dest."; }
}

# One row of the pending-handoff answers: the key, a padded label, and a dim
# consequence column, in the already-open menu's layout.
_resume_menu_row() {  # key color label consequence
    printf '    %b%b%s%b  %b%-16s%b%b%s%b\n' \
        "$BOLD" "$2" "$1" "$NC" "$WHITE" "$3" "$NC" "$DIM" "$4" "$NC"
}

launch_claude_code() {
    local session_name="$1"
    local session_dir="$2"
    local is_new="$3"
    local force="${4:-}"
    # What claude is told the session is called, and what ps shows for a
    # running one (cs_claude_name).
    local claude_name
    claude_name=$(cs_claude_name "$session_name")
    local merge_feature="${5:-}"
    # Set for `cs <name> --remote`: the permission mode the server passes to
    # the sessions it starts. Empty for every other open.
    local remote_mode="${6:-}"

    # The spawn token (see the seed consumer below) proves THIS window to
    # THIS session only. Taken into a plain variable and dropped from the
    # environment here, before the lock: its collision menu re-execs cs for
    # a feature of the session, and an exported token would ride along and
    # prove the redirected launch to a seed staged for that feature (Codex
    # round 2, audit H2).
    local _spawn_token="${CS_SPAWN_TOKEN:-}"
    unset CS_SPAWN_TOKEN

    # Acquire session lock before anything else
    acquire_session_lock "$session_dir/.cs" "$force" "$session_name" "${remote_mode:+remote}"
    # A force chosen at the collision menu is equivalent to --force for the
    # rest of the launch.
    [ "${CS_COLLISION_FORCE:-}" = "1" ] && force="true"
    # The traps read the path from a global when they fire, never from text
    # spliced into them: a " or $( in the sessions root would be run as code.
    # Global, not local: the EXIT trap fires after this function has returned.
    _CS_LOCK_META_DIR="$session_dir/.cs"
    trap 'reset_tab_title; _spawn_put_back_claim; release_session_lock "$_CS_LOCK_META_DIR"; _detach_opened_vault' EXIT
    # An INT that lands while cs_tmux_title_window holds the title lock makes
    # release_session_lock skip (one _cs_lock at a time); the lock left names
    # a dead pid and the next open reclaims it. Decided; do not re-fix.
    trap 'reset_tab_title; release_session_lock "$_CS_LOCK_META_DIR"; exit 130' INT TERM

    # Opening an archived session revives it. Placed after lock acquisition so
    # a cancelled collision menu leaves the marker in place; the removal is
    # left uncommitted, like every cs edit to session content.
    if [ -f "$session_dir/.cs/archived" ]; then
        rm -f "$session_dir/.cs/archived"
        notice .cs/archived "removed, so the session is active again"
    fi

    # Read the session's recorded UUID (allocated by create_session_structure
    # on new sessions or bound by migrate_session Phase 8 to a transcript on
    # disk). Used for both the CS_CLAUDE_SESSION_ID env export below and for
    # the spawn args at exec time. Empty on an existing session that has never
    # had a conversation, such as the first open after cs -adopt; the launch
    # below starts one and records it. Both recorded values reach claude's
    # argv, so each is checked here: a value that is not a UUID names no
    # conversation and counts as empty, a colour claude would reject passes no
    # colour. Neither is dropped without a line saying so.
    local claude_session_id claude_session_color
    claude_session_id=$(_read_local_state "$session_dir/.cs/local/state" claude_session_id)
    if [ -n "$claude_session_id" ] && ! _is_uuid "$claude_session_id"; then
        warn "ignoring claude_session_id in .cs/local/state: not a UUID, so it names no conversation"
        claude_session_id=""
    fi
    # No recorded conversation does not mean no conversation: a feature
    # worktree's open runs no migrate_session, so Phase 8 never looked, and a
    # dropped non-UUID leaves the slot empty with the transcript still on disk.
    # Look once at the folder's transcripts before calling the session unbound,
    # so a real conversation is offered rather than abandoned.
    if [ -z "$claude_session_id" ] && [ "$is_new" = "false" ]; then
        local _found
        _found=$(_discover_session_uuid_in "$(_claude_project_dir "$session_dir")")
        if _is_uuid "$_found"; then
            _set_local_state "$session_dir/.cs/local/state" claude_session_id "$_found"
            notice .cs/local/state "bound claude_session_id to $_found"
            claude_session_id="$_found"
        fi
    fi
    claude_session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)
    if [ -n "$claude_session_color" ] && ! _is_session_color "$claude_session_color"; then
        warn "ignoring claude_session_color in .cs/local/state: not one of claude's colours"
        claude_session_color=""
    fi

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
    # be holding it. Spares the ps fork on fresh-spawn. An unbound session
    # has no UUID to match, so only the --name half runs for it.
    if [ "$force" != "true" ] && [ "$is_new" != "true" ]; then
        local _ps_out
        _ps_out=$("${CS_PS_BIN:-ps}" -Ao args= 2>/dev/null || true)
        # An in-app /clear rebinds the recorded UUID while the live process's
        # argv still names its launch UUID, so the UUID test alone goes blind.
        # --name is stable for the process's whole life. The trailing delimiter
        # keeps a name that prefixes another (sym vs sym-comfy-nodes) from
        # matching; the appended newline covers --name being the final argument.
        # The UUID counts only after a flag claude takes it with (--session-id
        # at launch, --resume or -r on a continue, --parent-session-id on a
        # teammate that outlived its lead and still writes to .cs/local/): a
        # Bash-tool child carries the same UUID in the shell snapshot it is
        # started from, and one left running in the background outlives the
        # conversation as an orphan. Each flag in both spellings, with a space
        # or with `=`.
        _ps_out="$_ps_out"$'\n'
        local _flag _hit=""
        if [ -n "$claude_session_id" ]; then
            for _flag in "--session-id " "--session-id=" "--resume " "--resume=" " -r " "--parent-session-id " "--parent-session-id="; do
                if [[ "$_ps_out" == *"$_flag$claude_session_id "* ]] \
                    || [[ "$_ps_out" == *"$_flag$claude_session_id"$'\n'* ]]; then
                    _hit=1; break
                fi
            done
        fi
        # Both spellings of the name: a claude launched before cs mapped the
        # '@' still runs under it (cs_claude_name).
        if [ -n "$_hit" ] \
            || [[ "$_ps_out" == *"--name $claude_name "* ]] \
            || [[ "$_ps_out" == *"--name $claude_name"$'\n'* ]] \
            || [[ "$_ps_out" == *"--name $session_name "* ]] \
            || [[ "$_ps_out" == *"--name $session_name"$'\n'* ]]; then
            error "Session $session_name is live elsewhere${claude_session_id:+ (UUID $claude_session_id)}. Use --force to override."
        fi
    fi

    # Set environment variables
    export CLAUDE_SESSION_NAME="$session_name"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
    # A pane claude opens itself (an agent-team teammate) is started by the
    # tmux server, which hands it the server's session environment, not the
    # lead's: the truecolor override cs exported for claude never reaches it,
    # so the teammate's status line renders in the muted 256-colour fallback,
    # and neither does the sessions root, which the teammate's hooks need to
    # recognise this session when they walk in from its directory (a session
    # under a non-default root would decline). Publish both into the tmux
    # session this launch runs in, so panes split from it inherit them.
    # Best-effort: a pane cs did not launch is the documented fallback, not a
    # failure.
    if [ -n "${TMUX:-}" ]; then
        _tmux set-environment CLAUDE_CODE_TMUX_TRUECOLOR "$CLAUDE_CODE_TMUX_TRUECOLOR" 2>/dev/null || true
        _tmux set-environment CS_SESSIONS_ROOT "$SESSIONS_ROOT" 2>/dev/null || true
    fi
    _iterm_tab_through_tmux
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
    # A feature worktree keeps its own task list, keyed like its conversation
    # to the full `base@task` name: the base's list is the base's work, and a
    # feature opening on it would show and edit tasks that are not its own.
    # Secrets still key to the base (cs_base, worktree local state only).
    local cs_base
    cs_base=$(_read_local_state "$session_dir/.cs/local/state" cs_base)
    export CLAUDE_CODE_TASK_LIST_ID="$session_name"
    # Claude Code 2.1.233+ withholds the Task tools on Opus 4.8, Sonnet 5 and
    # Fable 5 unless the session opts in. The rotation wake, the walk-away
    # drain and the rotate skill all address the native task list, so a cs
    # launch opts in; CS_NO_TASK_TOOLS=1 hands the choice back to Claude Code.
    if [ -z "${CS_NO_TASK_TOOLS:-}" ]; then
        export CLAUDE_CODE_ENABLE_TODO_TOOLS=1
    fi
    # Claude Code loads function-hooks plugins only behind this early-access
    # flag, and the rotate mod the installer deploys is one. A cs launch turns
    # them on for the session, keeping a value the shell already set (0 keeps
    # them off). CS_NO_FUNCTION_HOOKS=1 leaves the session without the flag
    # even when the shell carried one, as a nested launch inherits it.
    if [ -n "${CS_NO_FUNCTION_HOOKS:-}" ]; then
        unset CLAUDE_CODE_ENABLE_FUNCTION_HOOKS
    else
        export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS="${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-1}"
    fi
    # The secrets identity is this session's alone: a base launched from a
    # shell inside a feature, or from one a cs -secrets arm started, would
    # otherwise hand its claude that session's target (CS_SECRETS_SESSION) or
    # caller (CS_SECRETS_CALLER), and cs-secrets reads both ahead of
    # CLAUDE_SESSION_NAME.
    if [ -n "$cs_base" ]; then
        export CS_SECRETS_SESSION="$cs_base"
    else
        unset CS_SECRETS_SESSION
    fi
    unset CS_SECRETS_CALLER
    # Export both names defensively: Claude Code's auto-memory resolver reads
    # CLAUDE_COWORK_MEMORY_PATH_OVERRIDE; the older CLAUDE_CODE_AUTO_MEMORY_PATH
    # is kept in case other Claude Code versions honor it instead.
    local memory_path="$session_dir/.cs/memory"
    export CLAUDE_CODE_AUTO_MEMORY_PATH="$memory_path"
    export CLAUDE_COWORK_MEMORY_PATH_OVERRIDE="$memory_path"
    _export_session_claude_config "$session_dir"
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
    # of the two is one test for "this conversation is the one cs launched" —
    # the session's single claude_session_id slot is its to rebind, and no
    # other claude's. Identity has to be the process, not the environment:
    # children inherit every exported variable, so a teammate or a headless
    # `claude -p` carries this value while owning a different pid.
    export CS_LEAD_PID=$$
    # The other test is the lead's claim on this launch, which its SessionStart
    # writes to .cs/local/lead-pid (cs_lead_claim): the resume arm runs claude
    # as this shell's child, and a CLAUDE_CODE_BIN that forks claude puts it
    # further below. A claim a previous launch left is keyed by that launch's
    # pid, which this one may have drawn again, so it goes before claude starts.
    # After the lock: a launch that met a live session and stopped at the
    # collision menu never gets here, so it leaves the live lead's claim.
    # A link there is removed, not followed. A directory may hold what
    # someone put there, so it is not removed: the open stops and names it.
    # CS_LEAD_CLAIM tells the hooks this launch clears the file and takes the
    # claim; under a launch without it they know the lead by the pid alone.
    local claim_file="$session_dir/.cs/local/lead-pid"
    if [ -d "$claim_file" ] && [ ! -L "$claim_file" ]; then
        error "$claim_file is a directory, where cs keeps the lead's claim on its launch; remove it and open the session again"
    fi
    rm -f "$claim_file"
    export CS_LEAD_CLAIM=1

    # Where this cs is, for the mods: `$.process.run` takes no shell and the
    # claude process's PATH is not this shell's. Set on every launch, so a
    # value inherited from a parent launch is always replaced by this one's.
    local self_bin
    self_bin="$(cd -- "$(dirname "$0")" && pwd -P)/$(basename "$0")"
    export CS_BIN="$self_bin"

    # The cs-update mod draws the pending release's notes and runs the update
    # from inside the session. It gets the launch's verdict, never its own:
    # the version check_update_notify found newer than this cs. Absent when
    # nothing is pending, so the mod is silent by absence rather than by a
    # value it has to read; cleared first, since a nested launch inherits its
    # parent's verdict. A version declined at the launch's question is named
    # beside it, so the mod says it is there instead of opening its pane.
    unset CS_UPDATE_AVAILABLE CS_UPDATE_DECLINED
    if [ -n "$UPDATE_AVAILABLE" ]; then
        export CS_UPDATE_AVAILABLE="$UPDATE_AVAILABLE"
        [ -z "$UPDATE_DECLINED_PENDING" ] || export CS_UPDATE_DECLINED="$UPDATE_AVAILABLE"
    fi

    # The session is open and every export above is in place: `--remote`
    # serves it through claude remote-control instead of starting claude.
    # A staged spawn seed stays staged for an interactive open, since the
    # server takes no prompt to kick it with, and one line says so.
    if [ -n "$remote_mode" ]; then
        [ ! -f "$SESSIONS_ROOT/.spawn/$session_name.seed" ] \
            || warn "A spawn seed is staged for $session_name; it stays staged for the next cs $session_name, since claude remote-control takes no prompt to start it with."
        _serve_remote "$session_name" "$session_dir" "$remote_mode"
    fi

    # Spawn seed: tasks and a brief staged by cs -spawn for this session.
    # Consumed here, after the already-running guard and before any exec arm,
    # so a window that died before launching self-heals on the session's next
    # open. A stale seed (>1h) is set aside with its brief, never silently
    # armed days later.
    #
    # Consent (audit H2): a seed is a file in .spawn/, and anything that can
    # write there could arm the next open of this name with its own tasks and
    # a kick that says "begin". Line 1 of the seed is a token the spawn's own
    # tmux window carries in CS_SPAWN_TOKEN; only that window consumes unasked.
    # Every other open (by hand, a script, a window that died and was reopened
    # elsewhere) is shown the seed as data and asked. The token was taken out
    # of the environment before the lock (above), so claude, a collision
    # redirect and any nested launch never carry it.
    local spawn_kick=""
    local _seed="$SESSIONS_ROOT/.spawn/$session_name.seed" _claim
    if [ -f "$_seed" ]; then
        local _now _age
        _now=$(date +%s)
        _age=$(( _now - $(_epoch_mtime "$_seed") ))
        if [ "$_age" -gt 3600 ]; then
            mv "$_seed" "$_seed.stale" 2>/dev/null || true
            warn "Stale spawn seed set aside: $_seed.stale (re-run cs -spawn if still wanted)"
        else
            # Read the seed once: line 1 the token, line 2 the spawner, then
            # one task per line up to the brief marker, if the seed has one;
            # the brief is the rest of the file and is never read as tasks.
            # Whitespace-only lines are skipped, not merely empty ones:
            # _queue_add trims and then errors on an empty body, which under
            # errexit would abort the whole session launch over a stray space
            # in a hand-edited seed.
            local _seed_token="" _spawner="" _line _lineno=0 _n=0 _mark
            local _tasks
            _tasks=()
            # Everything below reads the seed under a name this open owns
            # (_spawn_put_back_claim in lib/52-spawn.sh): a seed published in
            # .spawn while the consent ask waits is not the one shown, and the
            # tasks, the brief, a decline and the delete all belong to the
            # seed that was shown. The traps put it back if the open stops.
            _claim="$SESSIONS_ROOT/.spawn/.$session_name.seed.claim.$$"
            mv "$_seed" "$_claim" \
                || error "Spawn seed could not be read: $_seed (seed kept; re-open the session to retry)"
            _CS_SPAWN_SEED="$_seed"
            _CS_SPAWN_CLAIM="$_claim"
            _mark=$(_spawn_brief_mark_line "$_claim") \
                || error "Spawn seed could not be read: $_seed (seed kept; re-open the session to retry)"
            while IFS= read -r _line || [ -n "$_line" ]; do
                _lineno=$((_lineno + 1))
                [ "$_lineno" != "$_mark" ] || break
                case "$_lineno" in
                    1) _seed_token="$_line"; continue ;;
                    2) _spawner="$_line"; continue ;;
                esac
                case "$_line" in *[![:space:]]*) : ;; *) continue ;; esac
                _tasks+=("$_line")
                _n=$((_n + 1))
            done < "$_claim"
            # Never empty-equals-empty: a seed with no token line (older cs,
            # or hand-written) is foreign to every open.
            local _consume=1
            if [ -n "$_spawn_token" ] && [ "$_spawn_token" = "$_seed_token" ]; then
                :
            else
                _consume=0
                # Shown as data: control characters stripped, so a crafted
                # seed cannot draw over the question it is answering.
                local _shown_spawner _shown
                _shown_spawner=$(printf '%s' "$_spawner" | tr -d '[:cntrl:]')
                echo
                printf "${GOLD}A spawn seed is staged for this session:${NC} %s\n" "$_seed"
                printf '    spawner: %s\n' "${_shown_spawner:-(none)}"
                if [ -n "$_mark" ]; then
                    printf '    brief:   inline, %s bytes (becomes .cs/brief.md)\n' \
                        "$(tail -n +"$((_mark + 1))" "$_claim" | wc -c | tr -d ' ')"
                fi
                if [ "$_n" -gt 0 ]; then
                    printf '    tasks (queued and armed; the walk-away drain runs them unattended):\n'
                    local _i=0
                    for _line in ${_tasks[@]+"${_tasks[@]}"}; do
                        _i=$((_i + 1))
                        _shown=$(printf '%s' "$_line" | tr -d '[:cntrl:]')
                        printf '      %d. %s\n' "$_i" "$_shown"
                    done
                fi
                # The answer is a keypress on a terminal, never redirected
                # stdin: `cs name <<< ""` hands read a newline, which is the
                # empty answer the default arm took (Codex round 1), and a
                # script could type y as easily. With no terminal the seed
                # stays staged for an attended open and this launch goes on
                # without it. On a terminal: Enter or y takes the seed, n or
                # Escape sets the seed and brief aside like a stale pair so
                # the next open does not ask again, any other key asks
                # again, and EOF leaves it staged.
                if [ ! -t 0 ]; then
                    _spawn_put_back_claim
                    warn "Spawn seed left staged: $_seed (open $session_name in a terminal to answer, or remove it)"
                else
                    local _answer
                    while :; do
                        printf "${DIM}This open is not the spawn's own window.${NC} Take the seed? [Y/n] "
                        if ! IFS= read -rsn1 _answer; then
                            echo
                            _spawn_put_back_claim
                            warn "Spawn seed left staged: $_seed (open $session_name in a terminal to answer, or remove it)"
                            break
                        fi
                        echo
                        case "$_answer" in
                            ''|[yY]) _consume=1; break ;;
                            $'\e'|[nN])
                                _CS_SPAWN_CLAIM=""
                                mv "$_claim" "$_seed.stale" 2>/dev/null || true
                                warn "Spawn seed declined and set aside: $_seed.stale (re-run cs -spawn if still wanted)"
                                break ;;
                        esac
                    done
                fi
            fi
        fi
        if [ "${_consume:-0}" = 1 ]; then
            local _has_brief=0 _qdir
            # The spawner becomes the worker's report-back address, in
            # spawned-by and in the kick's `cs -msg <spawner>`, so a seed
            # being taken has it held to the session-name rules cs -spawn
            # holds it to, in a subshell since both rules exit on a bad name.
            # A seed that breaks them is refused before anything is written
            # or queued, and the trap puts it back. A seed left staged or
            # declined above is not taken, so nothing is asked of it.
            if [ -n "$_spawner" ] \
                && ! ( cs_split_worktree_name "$_spawner" || validate_session_name "$_spawner" ) >/dev/null 2>&1; then
                error "Spawn seed $_seed names a spawner that is not a session name: $(_cs_plain_name "$_spawner" 80) (seed kept; remove it or re-run cs -spawn, then re-open the session)"
            fi
            # The brief is written in before any task is queued, and a write
            # that fails stops the launch with the seed still staged, so the
            # next open retries. Consuming the seed regardless would start the
            # session without the brief it was opened for. errexit does not
            # see a failed left operand, so the abort is explicit.
            if [ -n "$_mark" ]; then
                # A link in the brief's place would turn the write into one
                # over whatever it names; a directory would take the file.
                [ ! -L "$session_dir/.cs/brief.md" ] \
                    || error "Spawn brief could not be delivered: $session_dir/.cs/brief.md is a link (seed kept; remove it and re-open the session to retry)"
                [ ! -d "$session_dir/.cs/brief.md" ] \
                    || error "Spawn brief could not be delivered: $session_dir/.cs/brief.md is a directory (seed kept; remove it and re-open the session to retry)"
                cs_write_atomic "$session_dir/.cs/brief.md" tail -n +"$((_mark + 1))" "$_claim" \
                    || error "Spawn brief could not be delivered to $session_dir/.cs/brief.md (seed kept; re-open the session to retry)"
                _has_brief=1
            fi
            # The queue is a cs content file: behind .cs/private in an
            # encrypted session, where the drain reads it. spawned-by is an
            # id and stays in .cs/local (docs/session-layout.md).
            _qdir=$(cs_private_dir "$session_dir/.cs") \
                || error "$session_name: .cs/private dangles after the open checked it (vault unmounted mid-launch?). Mount it, then reopen. (seed kept)"
            # Every write that can fail runs before the first task is queued:
            # a failure stops the open with the seed staged again, and that
            # seed is then the only copy of its tasks, so the retry queues
            # each one once.
            if [ -n "$_spawner" ] && { [ "$_n" -gt 0 ] || [ "$_has_brief" = 1 ]; }; then
                printf '%s\n' "$_spawner" > "$session_dir/.cs/local/spawned-by" 2>/dev/null \
                    || error "could not record the spawner in $session_dir/.cs/local/spawned-by (seed kept; fix it and re-open the session to retry)"
            fi
            # A task that cannot be queued takes back the ones this open queued
            # before it, so the seed put back is the only copy of its tasks. A
            # take-back that fails names every file left, for the person to
            # remove before a retry queues them again.
            local _queued=() _left=() _f
            for _line in ${_tasks[@]+"${_tasks[@]}"}; do
                if _queue_write_task "$_qdir" "$_line"; then
                    _queued+=("$_QUEUE_ADDED")
                    continue
                fi
                for _f in ${_queued[@]+"${_queued[@]}"}; do
                    rm -f "$_f" 2>/dev/null && [ ! -e "$_f" ] || _left+=("$_f")
                done
                if [ "${#_left[@]}" -gt 0 ]; then
                    error "could not write the task into $_qdir/queue; it is not queued, and ${#_left[@]} task(s) this open queued before it could not be taken back: ${_left[*]}. Remove them before re-opening the session, or the retry queues them again (seed kept)"
                fi
                error "could not write the task into $_qdir/queue; it is not queued (seed kept; the ${#_queued[@]} task(s) this open queued before it were taken back)"
            done
            # Once its tasks are queued the seed is spent: only the claimed
            # seed is deleted (one published since stays staged for its own
            # open), and a failure from here on cannot put it back to be
            # queued a second time.
            _CS_SPAWN_CLAIM=""
            rm -f "$_claim"
            if [ "$_n" -gt 0 ]; then
                _queue_set_state "$_qdir" armed \
                    || error "the seed's $_n task(s) are queued but the queue could not be armed; arm it with: cs $session_name -queue start"
            fi
            if [ "$_n" -gt 0 ] || [ "$_has_brief" = 1 ]; then
                local _work=""
                [ "$_has_brief" = 1 ] && _work="Your brief is .cs/brief.md: read it first."
                if [ "$_n" -gt 0 ]; then
                    _work="${_work:+$_work }Your walk-away queue is armed with $_n task(s); begin."
                else
                    _work="$_work Then begin."
                fi
                if [ -n "$_spawner" ]; then
                    spawn_kick="Spawned by $_spawner. $_work Send results with: cs -msg $_spawner -k result \"...\""
                else
                    spawn_kick="$_work"
                fi
            fi
        fi
    fi
    # Arming the ritual is an explicit action the user took seconds ago, so it
    # outranks a spawn seed staged earlier. The queue is already armed by this
    # point, so nothing is lost — but the drain is the Stop hook, which fires
    # at the first turn end, so do not promise it runs after the merge.
    local merge_kick=""
    [ -n "$merge_feature" ] && merge_kick="/finish $merge_feature"
    if [ -n "$merge_kick" ] && [ -n "$spawn_kick" ]; then
        warn "A walk-away queue is armed here; it will begin at the first turn end."
    fi
    # The kick prompt takes claude's single positional-prompt slot, displacing
    # the /color re-apply for this one launch (color returns next open).
    local launch_prompt="${merge_kick:-${spawn_kick:-$color_arg}}"

    # Status indicator. An existing session with no recorded conversation starts
    # its first one below, so it is new, not resuming.
    local status_icon status_text
    if [ "$is_new" = "true" ] || [ -z "$claude_session_id" ]; then
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

    # One bar per row, and the card can reach five: version, session, path,
    # secrets-and-context, update. The last colour repeats rather than the index
    # running off the end — under `set -u` that is an unbound-variable abort of
    # the whole launch, not a missing bar.
    local BAR5='\033[38;2;255;193;7m▌'    # amber-light #ffc107
    local BAR6='\033[38;2;255;202;40m▌'   # amber-lighter #ffca28
    local bar_idx=0
    local bars=("$BAR1" "$BAR2" "$BAR3" "$BAR4" "$BAR5" "$BAR6")

    echo ""
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${ORANGE}cs${NC} ${GREEN}$VERSION${NC}"; ((++bar_idx))
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${WHITE}${BOLD}$session_name${NC} ${COMMENT}($status_icon $status_text)${NC} ${DIM}${ICON_HOST} $(hostname -s)${NC}"; ((++bar_idx))
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${GOLD}$session_dir${NC}"; ((++bar_idx))
    # Secrets and context are one short fact each, so they share a row rather
    # than costing the card two. Built as segments and emitted once: either can
    # be absent (no secrets stored; a new session, which has no conversation for
    # a context figure to describe), and the row appears whenever at least one
    # is present.
    local _seg_secrets="" _seg_ctx=""
    if [ "$secret_count" -gt 0 ]; then
        local secret_word="secret"
        [ "$secret_count" -gt 1 ] && secret_word="secrets"
        _seg_secrets="${COMMENT}${ICON_LOCK}${NC} ${YELLOW}$secret_count${NC} ${COMMENT}$secret_word${NC}"
    fi
    if [ "$status_text" = "resuming" ]; then
        local _card_ctx=""
        _card_ctx=$(_resume_context_pct "$session_dir")
        if [ -n "$_card_ctx" ]; then
            _seg_ctx="${COMMENT}${ICON_CTX}${NC} ${YELLOW}${_card_ctx}%${NC} ${COMMENT}context used${NC}"
        fi
    fi
    if [ -n "$_seg_secrets" ] || [ -n "$_seg_ctx" ]; then
        local _row="$_seg_secrets"
        # Literal glyph, not an escape: /bin/bash 3.2 (the floor) prints
        # `\u00b7` from echo -e as six characters, and every other middle dot
        # in cs is a literal for the same reason.
        if [ -n "$_seg_secrets" ] && [ -n "$_seg_ctx" ]; then
            _row="${_row}  ${DIM}·${NC}  ${_seg_ctx}"
        else
            _row="${_row}${_seg_ctx}"
        fi
        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${_row}"; ((++bar_idx))
    fi

    if [ -n "$UPDATE_AVAILABLE" ]; then
        # The update block continues the card's bar stack rather than starting
        # its own column: same bar, same one-space gutter, so it reads as the
        # last fact about this session and not as a separate widget.
        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${BOLD}${YELLOW}${ICON_UP}${NC} ${BOLD}${GREEN}$UPDATE_AVAILABLE${NC} ${BOLD}${COMMENT}available${NC} ${BOLD}${DIM}(you have $VERSION — run${NC} ${BOLD}${GOLD}cs -update${NC}${BOLD}${DIM})${NC}"; ((++bar_idx))
        local notes_cache="$HOME/.cache/cs/update-notes-$UPDATE_AVAILABLE"
        # The cs-update mod draws these same notes in full inside the session
        # once function hooks are on, so printing them here too would be a
        # second copy of the same list. This card is the fallback for when
        # the mod is withheld: mirrors the export above (CS_NO_FUNCTION_HOOKS
        # set, or the flag pinned to 0) — it runs after that block, so the
        # exported value already carries both cases. KEEP IN SYNC with
        # _rotate_force_notice's identical check.
        local _mod_withheld=""
        case "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-}" in ''|0) _mod_withheld=1 ;; esac
        if [ -n "$_mod_withheld" ] && [ -s "$notes_cache" ]; then
            local card_w nver nsum indent wrap_w line first
            card_w=$(tput cols 2>/dev/null) || card_w=80
            case "$card_w" in ''|*[!0-9]*) card_w=80 ;; esac
            # "▌ " + the note's own 3-space indent, and a right margin so the
            # text never touches the edge. Wrapped on word boundaries with
            # `fold -s` instead of cut mid-word: a summary that stops at "that
            # re" reads as a rendering bug, and the cache holds full sentences.
            indent="     "
            wrap_w=$((card_w - ${#indent} - 2))
            [ "$wrap_w" -ge 24 ] || wrap_w=24
            # A bare bar between the "available" line and the notes: they are a
            # different kind of thing (what changed, versus what to run), and
            # run together they read as one wrapped paragraph.
            echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC}"
            while IFS=$'\t' read -r nver nsum; do
                [ -n "$nsum" ] || continue
                first=1
                # Continuation lines align under the summary, not under the
                # version, so a wrapped note reads as one paragraph.
                while IFS= read -r line; do
                    if [ -n "$first" ] && [ "$nver" != "+" ]; then
                        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${DIM}  ${NC}${GREEN}${nver}${NC} ${COMMENT}${line}${NC}"
                        first=""
                    else
                        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${indent}${COMMENT}${line}${NC}"
                    fi
                done <<EOF
$(printf '%s\n' "$nsum" | fold -s -w "$wrap_w")
EOF
            done < "$notes_cache"
            ((++bar_idx))
        fi
    fi
    # One notice per machine that the forcing is on, after the card so it reads
    # as news about cs rather than a fact about this session.
    _rotate_force_notice

    echo ""

    # Title the terminal tab; the session colour stays inside the terminal
    # (band rule, status line, pill), never on the tab.
    set_tab_title "cs: $session_name" "$session_name"

    cd -- "$session_dir"

    # For existing sessions, ask if user wants to continue previous conversation.
    # The answer sets the id to resume; it goes to claude as one quoted argument.
    # An existing session with no recorded conversation has nothing to resume:
    # the first open after cs -adopt, or records whose machine-local state did
    # not travel. It takes the fresh answer without asking, unless a rotation
    # handoff is pending: that is the user's call, so the offer is made with
    # the rows that apply.
    local resume_id=""
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
                # skips teammates and headless runs, so when the recorded slot
                # is itself a teammate's — the state this gate exists to stop — what comes
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
        # An encrypted session keeps its handoffs and the marker in its vault;
        # the open has already refused a locked one.
        local pending_handoff="" _hf _handoff_dir _marker_dir
        _handoff_dir=$(cs_handoff_dir "$session_dir/.cs") \
            || error "$session_name: .cs/private dangles after the open checked it (vault unmounted mid-launch?). Mount it, then reopen."
        _marker_dir=$(cs_private_dir "$session_dir/.cs") \
            || error "$session_name: .cs/private dangles after the open checked it (vault unmounted mid-launch?). Mount it, then reopen."
        # .cs/handoffs/ is tracked, so a clone chooses the file names. Only a
        # plain one is offered: the name printed, armed and handed to Claude
        # is then the file itself. Any other is passed over, and one line says
        # so without naming it: it says which directory, and that the file may
        # be a clone's, so renaming it is not adopting it blind.
        local _skipped=""
        for _hf in "$_handoff_dir"/*.md; do
            [ -f "$_hf" ] || continue
            _handoff_is_unconsumed "$_hf" || continue
            _cs_is_plain_name "${_hf##*/}" || { _skipped=1; continue; }
            pending_handoff="$_hf"
        done
        [ -z "$_skipped" ] \
            || printf "${DIM}Skipped a rotation handoff in %s/ whose file name is not plain (only letters, digits and ._@-, at most 160 characters); check who wrote it before renaming it.${NC}\n" \
                "${_handoff_dir#"$session_dir/"}"
        # .cs/handoffs/ is shared and nothing ever deletes a handoff, so a file
        # belonging to another checkout keeps status: unconsumed indefinitely —
        # the rotate skill will not supersede one whose parent is absent from
        # this machine's session.log, and correctly so. Sorting last, it would
        # shadow the handoff this machine armed and r would rotate into someone
        # else's plan. An armed marker is an explicit choice, so it outranks the
        # scan; a marker naming a spent or absent file is stale and the scan
        # still answers. The marker names a basename, never a path: a separator
        # would resolve outside the handoff store. It names a plain one, as
        # the scan offers, or nothing.
        local _marker="$_marker_dir/pending-handoff" _armed
        if [ -f "$_marker" ]; then
            _armed=$(cat "$_marker" 2>/dev/null | tr -d '[:space:]' || true)
            case "$_armed" in */*|*\\*) _armed="" ;; esac
            _cs_is_plain_name "$_armed" || _armed=""
            if [ -n "$_armed" ] && [ -f "$_handoff_dir/$_armed" ] \
                && _handoff_is_unconsumed "$_handoff_dir/$_armed"; then
                pending_handoff="$_handoff_dir/$_armed"
            fi
        fi
        # A spawned launch is unattended: take the default (resume) instead
        # of parking the tmux window on an interactive ask. Unbound, the
        # default is fresh, and a pending handoff waits for an attended open.
        if [ -n "$spawn_kick" ]; then
            response=""
            [ -n "$claude_session_id" ] || response="n"
        elif [ -z "$claude_session_id" ] && [ -z "$pending_handoff" ]; then
            response="n"
        else
            if [ -n "$pending_handoff" ]; then
                # Answering blind is the hazard this label exists for: r arms
                # the marker with this basename, and the next SessionStart flips
                # that file to consumed under this machine's UUID — on a
                # colleague's live rotation, that is their artifact being taken.
                local _origin=""
                _handoff_is_local "$pending_handoff" "$session_dir" \
                    || _origin=" ${DIM}(from another checkout)${NC}"
                # .cs/handoffs/ is tracked, so a clone chooses the file name:
                # it is printed as a plain name.
                printf "${DIM}Rotation handoff pending:${NC} %s%b\n" "$(_cs_plain_name "$(basename "$pending_handoff")" 160)" "$_origin"
                # One answer per row, key first, laid out like the already-open
                # menu; the keys stay the letters the one-line ask used.
                echo
                if [ -n "$claude_session_id" ]; then
                    _resume_menu_row y "$GREEN" 'resume' 'continue the previous conversation · default'
                    _resume_menu_row r "$GOLD" 'from handoff' 'fresh conversation that picks up the handoff'
                    _resume_menu_row n "$COMMENT" 'fresh' 'fresh conversation; the handoff waits for later'
                    _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then resume'
                else
                    _resume_menu_row r "$GOLD" 'from handoff' 'fresh conversation that picks up the handoff'
                    _resume_menu_row n "$COMMENT" 'fresh' 'fresh conversation; the handoff waits for later · default'
                    _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then start fresh'
                fi
                echo
                printf '    %b›%b ' "$GOLD" "$NC"
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
                resume_id=""
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    mkdir -p "$_marker_dir"
                    printf '%s\n' "$(basename "$pending_handoff")" > "$_marker_dir/pending-handoff"
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
                resume_id="$claude_session_id"
                ;;
            [dD])
                # Nothing survives d: it retires the handoff it was offered, and
                # an orphaned marker had none to begin with.
                _disarm_rotation_marker "$session_dir"
                if [ -n "$pending_handoff" ]; then
                    # Flip only the first status line (the frontmatter's); a
                    # body quoting the contract line flush-left stays intact.
                    cs_write_atomic "$pending_handoff" awk '
                        !flipped && $0 == "status: unconsumed" {
                            print "status: discarded"
                            flipped = 1
                            next
                        }
                        { print }
                    ' "$pending_handoff" 2>/dev/null || true
                    printf "${DIM}Handoff discarded:${NC} %s\n" "$(_cs_plain_name "$(basename "$pending_handoff")" 160)"
                fi
                # d without a pending handoff was never offered: treat as the
                # default resume answer.
                resume_id="$claude_session_id"
                ;;
            *)
                # Also the unattended spawn path, which takes this default
                # without asking.
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                # --resume <uuid>, never --continue: the uuid names the exact
                # conversation, while --continue means "most recent" and may
                # resolve to a sibling Claude session the user ran in a
                # different terminal between cs launches. Empty on an unbound
                # session, which the fresh path below starts.
                resume_id="$claude_session_id"
                ;;
        esac
        echo ""
    fi

    if [ -n "$resume_id" ]; then
        # tmux names a pane after the leader of its foreground process group,
        # and iTerm2 takes the tab's icon from that name, so claude replaces
        # cs when the resume is sure to land. exec keeps the pid: the session
        # lock names claude, as on a fresh launch.
        if _resume_lands_in_place "$session_dir" "$resume_id"; then
            # Unquoted on purpose here and below: CLAUDE_CODE_BIN may carry
            # flags after the command, and _claude_bin_word checks that word.
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$claude_name" --resume "$resume_id" ${launch_prompt:+"$launch_prompt"}
        fi
        # Otherwise claude decides whether the conversation resumes, and cs
        # stays to start a fresh one if it cannot and to detach a vault.
        # CS_LEAD_PID is this shell's pid and claude is its child here, so the
        # hooks know the lead by the claim its SessionStart writes (cs_is_lead).
        SECONDS=0
        local rc=0
        # shellcheck disable=SC2086
        $CLAUDE_CODE_BIN --name "$claude_name" --resume "$resume_id" ${launch_prompt:+"$launch_prompt"} || rc=$?
        # A claude can end because its session was removed under it
        # (cs -rm --force while it ran). The fresh start below would write
        # .cs/local/state again with mkdir -p and launch a claude in a
        # directory that is gone, so cs leaves with claude's status. This
        # open made .cs moments ago; with it gone there is no session here.
        [ -d "$session_dir/.cs" ] || exit $rc
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
        #   - is_new=false (user said N to resume, or the session has no
        #     recorded conversation): rebind to a fresh UUID and pass
        #     --session-id <new> so cs stays bound to the new conversation.
        #     Without rebind, next launch resumes the OLD conversation while
        #     the fresh one becomes orphaned.
        #   - is_new=true with no claude_session_id (create_session_structure
        #     always writes one; handled defensively): naked exec.
        if [ "$is_new" = "true" ] && [ -n "$claude_session_id" ]; then
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$claude_name" --session-id "$claude_session_id" ${launch_prompt:+"$launch_prompt"}
        elif [ "$is_new" = "false" ]; then
            _exec_fresh_rebind "$session_dir" declined-resume "" "$spawn_kick" "$merge_kick"
        else
            # shellcheck disable=SC2086
            exec $CLAUDE_CODE_BIN --name "$claude_name" ${launch_prompt:+"$launch_prompt"}
        fi
    fi
}

# A resume may run in place of cs when it is sure to land and cs has nothing
# to do after it: claude reads its transcripts from where cs looks (no
# CLAUDE_CONFIG_DIR set at all, even empty), the transcript holds a whole
# top-level user record (a torn line, or a user message nested inside
# another record, does not count), and no vault waits on cs to detach it
# when claude ends without its hooks. Without jq the resume stays a child.
_resume_lands_in_place() {  # session_dir, conversation id
    local file
    [ -f "$1/.cs/local/vault" ] && return 1
    [ -z "${CLAUDE_CONFIG_DIR+set}" ] || return 1
    file="$(_claude_project_dir "$1")/$2.jsonl"
    [ -f "$file" ] || file=$(_relocated_worktree_transcript "$1" "$2") || return 1
    [ -f "$file" ] && command -v jq >/dev/null 2>&1 || return 1
    jq -n -R -e 'first(inputs | fromjson? | objects | select(.type == "user")) | true' \
        "$file" >/dev/null 2>&1
}

# The transcript of a session's conversation once `claude --worktree` has
# exited: Claude Code moves it into the parent repo's project dir, and
# `claude --resume <id>` run from the worktree still finds it there (measured
# on 2.1.289). That dir also holds the parent's own conversations, so the file
# counts only when it began in this worktree, by the record and first-prompt
# checks of _discover_worktree_uuid_in, applied to that one file: the worktree
# can hold older conversations than its newest, and the parent's other files
# are never read. Discovery's bystander test is not applied: the id is the
# session's already, and that test reads the first prompt's whole line, so a
# prompt that only names the teammate frame would unbind it. The base dir is
# the session's own, which is where the claude cs launches for this session
# reads. Prints the path; fails when the session is no linked worktree or the
# conversation did not begin in it.
_relocated_worktree_transcript() {  # session_dir, conversation id
    local git_dir common parent proj
    git_dir=$(_git_path_abs "$1" --git-dir) || return 1
    common=$(_git_path_abs "$1" --git-common-dir) || return 1
    [ "$git_dir" -ef "$common" ] && return 1
    parent=$(cd -- "$common/.." 2>/dev/null && pwd -P) || return 1
    proj="$(dirname "$(_claude_project_dir "$1")")/$(_claude_encode_path "$parent")"
    [ -f "$proj/$2.jsonl" ] || return 1
    _is_worktree_started_transcript "$proj/$2.jsonl" "$(_worktree_json_path "$1")" || return 1
    printf '%s\n' "$proj/$2.jsonl"
}

# Follow a chain of symlinks to the file at its end, portably (BSD readlink
# has no -f before macOS 12.3). Prints the final path.
_resolve_symlink_file() {  # path
    local path="$1" target
    while [ -L "$path" ]; do
        target=$(readlink "$path") || break
        case "$target" in
            /*) path="$target" ;;
            *)  path="$(dirname "$path")/$target" ;;
        esac
    done
    printf '%s\n' "$path"
}

# Give a claude launched inside tmux under iTerm2 the tab it gets when iTerm2
# runs it directly: the progress loader along the top of the tab and the
# Claude icon beside its title. Neither reaches the tab on its own through tmux.
#
# Loader: Claude Code sends its progress escape (OSC 9;4, wrapped for tmux
# passthrough) only when TERM_PROGRAM names iTerm.app at 3.6.6 or later, and
# tmux replaces TERM_PROGRAM with its own name. iTerm2's real name and version
# are still in LC_TERMINAL and LC_TERMINAL_VERSION, so claude gets those.
# Claude Code also reads iTerm.app in TERM_PROGRAM with a TERM that is not
# screen* or tmux* as tmux -CC; that holds only when the attached client is in
# control mode, so in plain tmux with such a TERM claude keeps tmux's name.
#
# Icon: iTerm2 picks a tab's icon from the job's process name, and under tmux
# that name is the one tmux reports, the basename of the executable file. The
# native installer runs versions/<version> through a symlink, so the name is
# the version number. A hard link named claude to the same file carries the
# right name. It lives in a directory per version and goes when the installer
# removes that version; a launch that cannot make it runs claude as before.
# The command word of CLAUDE_CODE_BIN is linked only when it resolves to a
# versions/<version> file, the native installer's layout; the words after it
# stay as given. Any other binary or install is run as given.
_iterm_tab_through_tmux() {
    [ -n "${TMUX:-}" ] && [ "${LC_TERMINAL:-}" = iTerm2 ] && [ -z "${CS_NO_ITERM2:-}" ] || return 0

    if [ "${TERM_PROGRAM:-}" != iTerm.app ] && [ -n "${LC_TERMINAL_VERSION:-}" ]; then
        local control_mode
        control_mode=$(_tmux display-message -p '#{client_control_mode}' 2>/dev/null) || control_mode=""
        case "$control_mode:${TERM:-}" in
            1:*|*:screen*|*:tmux*)
                export TERM_PROGRAM=iTerm.app
                export TERM_PROGRAM_VERSION="$LC_TERMINAL_VERSION"
                ;;
        esac
    fi

    local word rest found real link version
    word=$(_claude_bin_word)
    [ -n "$word" ] || return 0
    rest="${CLAUDE_CODE_BIN#*"$word"}"
    found=$(command -v "$word" 2>/dev/null) || return 0
    real=$(_resolve_symlink_file "$found")
    # Only the native installer's versions/<version> file is self-contained;
    # an npm cli.js loads files beside it, which a hard link elsewhere loses.
    # The file must sit directly in a versions directory and be named by a
    # dotted version number alone.
    version="${real##*/}"
    [ "${real%/*}" != "$real" ] && [ "$(basename "${real%/*}")" = versions ] || return 0
    case "$version" in
        *[!0-9.]*|.*|*.|*..*) return 0 ;;
        *.*.*) ;;
        *) return 0 ;;
    esac
    # Every launch site expands CLAUDE_CODE_BIN unquoted, since a user value
    # may carry arguments, so a path with whitespace would split there.
    local links="$HOME/.local/share/cs/claude"
    case "$links" in *[[:space:]]*) return 0 ;; esac
    # One directory per version: a launch that resolved this version runs it
    # even if another launch links a newer one before this one execs.
    link="$links/$version/claude"
    if ! [ "$link" -ef "$real" ]; then
        mkdir -p "$(dirname "$link")" 2>/dev/null || return 0
        # Link beside the target name and rename over it, so a concurrent
        # launch never finds the name missing.
        ln -f "$real" "$link.$$" 2>/dev/null || return 0
        mv -f "$link.$$" "$link" 2>/dev/null || { rm -f "$link.$$"; return 0; }
    fi
    # A launch marks the directory it picked; another launch may still be
    # waiting to exec that link, at the resume prompt for one.
    touch "$(dirname "$link")" 2>/dev/null || true
    # A link keeps its file's data alive after the installer removes the
    # version; drop those nobody has picked for a day. A claude still running
    # from one keeps its copy. Two launches can prune the same directory, so
    # a removal that finds it gone is not an error.
    # Do not re-fix: a prune can still race a launch that picks the same
    # directory between find and rm, but only if the installer removes that
    # version's file in the same moment. It removes only versions that are
    # no longer current, and a launch only picks the current one (Codex
    # review round 3, accepted 2026-10-05).
    local old
    while IFS= read -r old; do
        [ -e "$(dirname "$real")/$(basename "$old")" ] && continue
        { rm -f "$old/claude"; rmdir "$old"; } 2>/dev/null || true
    done < <(find "$links" -mindepth 1 -maxdepth 1 -type d -mtime +1 2>/dev/null)
    CLAUDE_CODE_BIN="$link$rest"
}

# Run secrets subcommand
