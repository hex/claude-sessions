# ABOUTME: Health checks for keychain, hooks, shadow ref, memory, statusline, and tokens.
# ABOUTME: Backs 'cs -doctor' / 'cs -diag'.

_doctor_ok()   { printf "  ${GREEN}[ OK ]${NC} %s\n" "$1"; }
_doctor_warn() { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
_doctor_fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); }
_doctor_info() { printf "  ${DIM}[INFO]${NC} %s\n" "$1"; }

# True when the settings file parses as JSON. Every settings check below reads
# it through jq with stderr discarded, where a parse failure is indistinguishable
# from an empty result — which is how a single syntax error produced a screen of
# OKs: no hooks missing, no hook paths broken, "0 hooks, 0 MCPs", statusline
# "not registered (optional)". Consumers ask this first and say "unreadable"
# instead of "none".
# CALLERS MUST CHECK `command -v jq` FIRST. With no jq this returns false via
# exit 127, which is indistinguishable from a parse failure — so an unguarded
# caller states, falsely and with confidence, that a perfectly good settings
# file is malformed. That is the lying-diagnostic class this whole family of
# gates exists to remove.
_doctor_settings_parse_ok() {  # settings
    jq -e . "$1" >/dev/null 2>&1
}

# A jq definition of every hook in settings.json: .hooks is event -> [{matcher,
# hooks: [{type, command, ...}]}]. Install and uninstall keep whatever else the
# user wrote there (an event that is not a list, an entry or a hook that is
# not an object), and Claude Code runs none of it as a hook, so only the
# objects in the lists are walked; anything else would stop jq mid-stream.
_DOCTOR_JQ_HOOKS='def cs_hooks: objects | .hooks | objects | .[] | arrays | .[] | objects | .hooks | arrays | .[] | objects;'

_doctor_check_settings_valid() {
    local settings="${CS_CLAUDE_DIR:-$HOME/.claude}/settings.json"
    # Something there that is not a regular file (a FIFO, a device, a
    # directory) is never opened: reading a FIFO waits for a writer. Every
    # settings check below tests -f before it reads.
    if [ -e "$settings" ] && [ ! -f "$settings" ]; then
        _doctor_fail "Settings: $settings is not a regular file, so cs did not read it"
        return 0
    fi
    # A missing file is the hooks check's story to tell, with its own advice.
    [ -f "$settings" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_warn "Settings: jq not installed; $settings could not be validated"
        return 0
    fi
    if _doctor_settings_parse_ok "$settings"; then
        _doctor_ok "Settings: $settings is valid JSON"
    else
        _doctor_fail "Settings: $settings is not valid JSON — fix it first; every check below that reads it is unreliable"
    fi
}

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
    local names registered missing=()
    names=$(cd -- "$hooks_dir" && ls *.sh 2>/dev/null || true)
    [ -z "$names" ] && { _doctor_warn "Hooks: no .sh files in $hooks_dir"; return; }
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_warn "Hooks: jq not installed; registration in $settings could not be checked"
        return
    fi
    if ! _doctor_settings_parse_ok "$settings"; then
        _doctor_fail "Hooks: cannot read $settings (invalid JSON); registration unknown"
        return
    fi
    # The registered set is the hook COMMANDS, not the whole file. Matching the
    # file as text passed a broken install whenever a hook path lingered in an
    # unrelated permission rule or env value: the hook never fires, and doctor
    # called the install healthy.
    if ! registered=$(jq -r "$_DOCTOR_JQ_HOOKS"' cs_hooks | .command | strings' "$settings" 2>/dev/null); then
        _doctor_fail "Hooks: cannot read the hook events in $settings; registration unknown"
        return
    fi
    local name lib is_lib
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        # Hook libraries are sourced by the hooks, never invoked by Claude Code,
        # so they ship into the deploy dir without ever being named in
        # settings.json. Absent this skip, the glob below reports every one of
        # them as a missing registration on a correct install.
        is_lib=0
        for lib in "${CS_HOOK_LIBS[@]}"; do
            [ "$name" = "$lib" ] && { is_lib=1; break; }
        done
        [ "$is_lib" = 1 ] && continue
        case "$registered" in
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

# True when the current directory is the cs source checkout that produced the
# install: it holds hooks/, install.sh and bin/cs, and its bin/cs carries the
# version install.sh stamped into the deploy directory.
_doctor_in_installed_checkout() {
    local hooks_dir="$HOOKS_DEPLOY_DIR"
    [ -d "hooks" ] && [ -f "install.sh" ] && [ -f "bin/cs" ] || return 1

    # Those three names are not proof this checkout produced the install. Any
    # directory holding them passes, and a scratch copy of the repo is an
    # ordinary thing to be standing in — comparing its hooks against the
    # deployed ones reports drift naming files nobody edited, and advises
    # `./install.sh`, which from there installs something else. install.sh
    # stamps the deploy directory with the version it shipped, so compare
    # against that and stay silent when it is a different tree.
    # Both reads are guarded on the file existing rather than leaning on 2>/dev/null:
    # a missing file makes the first stage of the pipe exit non-zero, pipefail
    # promotes that to the assignment, and errexit ends the whole run here — so
    # every check after this one would silently never print. A machine with
    # nothing installed has no stamp, which is the ordinary case, not an error.
    local src_version="" deployed_version=""
    [ -f "bin/cs" ] &&
        src_version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' bin/cs 2>/dev/null | head -1)
    [ -f "$hooks_dir/.version" ] &&
        deployed_version=$(tr -d '[:space:]' < "$hooks_dir/.version" 2>/dev/null)
    [ -n "$src_version" ] && [ "$src_version" = "$deployed_version" ]
}

# Compares deployable artifacts in the current directory's cs source checkout
# (hooks/*.sh, hooks/*.md, commands/*.md, skills/*/SKILL.md) against their deployed
# copies. A source edit only takes effect once install.sh deploys it, so
# silent drift between the two means the running install doesn't match what
# the source says it does. Silent outside the checkout that produced the
# install.
_doctor_check_hook_drift() {
    local hooks_dir="$HOOKS_DEPLOY_DIR"
    local commands_dir="${CS_COMMANDS_DIR:-$HOME/.claude/commands}"
    local skills_dir="${CS_SKILLS_DIR:-$HOME/.claude/skills}"
    _doctor_in_installed_checkout || return 0

    local clean=1

    # area label, deploy root, source paths — reported per artifact kind.
    # Skills deploy as <name>/SKILL.md; everything else deploys flat, keyed
    # on the source path shape so the label stays purely cosmetic. A deployed
    # copy cs did not write (_cs_owns_file, as install.sh decides) is one
    # ./install.sh keeps as the user's, so it is named apart, with advice
    # that can clear it.
    _drift_scan() {
        local label="$1" deploy_root="$2"
        shift 2
        local drifted=() users_copies=() missing=() src name deployed
        for src in "$@"; do
            [ -e "$src" ] || continue
            if [[ "$src" == */SKILL.md ]]; then
                name=$(basename "$(dirname "$src")")
                deployed="$deploy_root/$name/SKILL.md"
            elif [[ "$src" == skills/*/scripts/* ]]; then
                name="${src#skills/}"
                deployed="$deploy_root/$name"
            elif [[ "$src" == mods/* ]]; then
                name="${src#mods/}"
                deployed="$deploy_root/$name"
            else
                name=$(basename "$src")
                deployed="$deploy_root/$name"
            fi
            if [ ! -f "$deployed" ]; then
                missing+=("$name")
            elif ! cmp -s "$src" "$deployed"; then
                if _cs_owns_file "$deployed"; then
                    drifted+=("$name")
                else
                    users_copies+=("$name")
                fi
            fi
        done
        if [ ${#drifted[@]} -gt 0 ]; then
            _doctor_warn "$label drift: deployed copy differs from source: ${drifted[*]} (run ./install.sh)"
            clean=0
        fi
        if [ ${#users_copies[@]} -gt 0 ]; then
            _doctor_warn "$label drift: deployed copy differs from source: ${users_copies[*]} (kept as yours, so ./install.sh does not replace it; move it aside, then run ./install.sh to get cs's copy)"
            clean=0
        fi
        if [ ${#missing[@]} -gt 0 ]; then
            _doctor_warn "$label drift: not deployed: ${missing[*]} (run ./install.sh)"
            clean=0
        fi
    }

    _drift_scan "Hook" "$hooks_dir" hooks/*.sh hooks/*.png hooks/*.md
    _drift_scan "Command" "$commands_dir" commands/*.md
    _drift_scan "Skill" "$skills_dir" skills/*/SKILL.md skills/*/scripts/*.sh
    local mod_srcs=() kept src
    for src in mods/*/.claude-plugin/plugin.json mods/*/hooks/* mods/*/tips.json; do
        for kept in ${CS_MODS_KEPT_OUT[@]+"${CS_MODS_KEPT_OUT[@]}"}; do
            case "$src" in "mods/$kept/"*) continue 2 ;; esac
        done
        mod_srcs+=("$src")
    done
    _drift_scan "Mod" "$skills_dir" ${mod_srcs[@]+"${mod_srcs[@]}"}

    if [ "$clean" = "1" ]; then
        _doctor_ok "Deploy drift: hooks, commands, skills, and mods match checkout source"
    fi
}

# Holds the installed picker to the checkout install.sh copied it from, which
# install.sh records in the deploy directory's .tui-origin ("checkout <path>"
# or "release"), so doctor checks it from any folder. install.sh copies a
# cs-tui it never builds, so a merge that rewrites tui/src leaves both the
# cargo build and the installed copy where they were, and the picker runs
# stale with nothing to say so. Two facts are read: the build is older than a
# file cargo would rebuild it from (cargo's own test is an mtime test too),
# and the installed bytes are not the build's. Silent with no installed
# picker, a release picker, a picker that is a symlink (install.sh keeps a
# link to content it did not write, so the picker is the user's own), and a
# recorded checkout with no build. With no usable record, or a recorded
# checkout that no longer holds the TUI, one untagged line says the picker was
# not checked and what fixes that.
_doctor_check_tui_build() {
    local installed="$HOME/.local/bin/cs-tui" origin_file="$HOOKS_DEPLOY_DIR/.tui-origin"
    [ -f "$installed" ] || return 0
    [ ! -L "$installed" ] || return 0

    local origin="" checkout shown
    [ -f "$origin_file" ] && { origin=$(cat "$origin_file" 2>/dev/null) || origin=""; }
    # install.sh writes one line; a record of more is not one it wrote, so no
    # line of it is taken for the checkout.
    case "$origin" in
        release) return 0 ;;
        *$'\n'*) checkout="" ;;
        "checkout /"*) checkout="${origin#checkout }" ;;
        *) checkout="" ;;
    esac
    if [ -z "$checkout" ]; then
        printf '  %s\n' "cs-tui: not checked: nothing in $origin_file says where $installed came from; the next ./install.sh from your checkout records it, and cs -update records it where a release picker exists for this platform (and replaces a checkout-built picker with the release one)"
        return 0
    fi
    # One trailing slash is dropped, so the rows join the path to tui/ with one.
    [ "$checkout" = / ] || checkout="${checkout%/}"
    # The checkout path as cs prints any name (_printable_name), so a control
    # character in it cannot drive the terminal; the advice commands quote it
    # with %q instead, so they paste back as the same path.
    shown=$(_printable_name "$checkout")
    if [ ! -f "$checkout/tui/Cargo.toml" ]; then
        printf '  %s\n' "cs-tui: not checked: $installed came from $shown, which holds no tui/Cargo.toml now; run ./install.sh from your checkout, or cs -update"
        return 0
    fi

    # The build install.sh ships: tui/target/release/cs-tui, unless bin/cs-tui
    # is newer. install.sh, the advice below, must be able to clear the row.
    local build="bin/cs-tui"
    if [ -f "$checkout/tui/target/release/cs-tui" ] && { [ ! -f "$checkout/$build" ] || [ "$checkout/tui/target/release/cs-tui" -nt "$checkout/$build" ]; }; then
        build="tui/target/release/cs-tui"
    fi
    [ -f "$checkout/$build" ] || return 0

    # Cargo rebuilds only from the files rustc reads, so under tui/src only
    # *.rs counts: a .DS_Store or a merge's .orig newer than the build is no
    # reason to rebuild, and a rebuild would not clear a row that counted it.
    # Paths are relative to the checkout, so its name never reaches -path.
    local inputs=() input newer quoted
    printf -v quoted '%q' "$checkout"
    if ! newer=$(
        cd -- "$checkout" || exit 1
        for input in tui/src tui/Cargo.toml tui/Cargo.lock tui/build.rs tui/.cargo/config.toml; do
            [ -e "$input" ] && inputs+=("$input")
        done
        find "${inputs[@]}" -type f \( ! -path 'tui/src/*' -o -name '*.rs' \) -newer "$build" 2>/dev/null
    ); then
        _doctor_warn "cs-tui: could not read the TUI source under $shown/tui to compare it with the build $shown/$build"
        return 0
    fi
    if [ -n "$newer" ]; then
        _doctor_warn "cs-tui: the TUI source under $shown/tui changed after the build $shown/$build, so the installed picker may be stale (run cargo build --release --manifest-path $quoted/tui/Cargo.toml, then $quoted/install.sh)"
    elif ! cmp -s "$checkout/$build" "$installed"; then
        _doctor_warn "cs-tui: the installed $installed differs from the build $shown/$build (run $quoted/install.sh)"
    else
        _doctor_ok "cs-tui: the installed picker matches the build $shown/$build"
    fi
}

# iTerm2 awareness, reported only when running inside iTerm2: the tab title
# ships via native escapes regardless; the attention dock bounce needs the
# it2 utilities from iTerm2 shell integration (~/.iterm2, not on PATH).
_doctor_check_iterm2() {
    [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || return 0
    if [ -n "${CS_NO_ITERM2:-}" ]; then
        _doctor_ok "iTerm2: integrations disabled (CS_NO_ITERM2)"
    elif [ -x "${CS_IT2_DIR:-$HOME/.iterm2}/it2attention" ]; then
        _doctor_ok "iTerm2: attention bounce active (it2 utilities found)"
    else
        _doctor_ok "iTerm2: attention bounce off (shell integration not installed)"
    fi
}

# One row per session `cs <name> --remote` serves or served: cs records the
# server's pid in .cs/local/remote.pid, and a process it starts beside the
# server removes the file once the server exits. A file whose pid no longer
# runs that server (_remote_server_pid) means that process never got to (it
# was killed, or the machine restarted), and the pid is gone or belongs to
# another program by now. The doctor removes such a file and says so.
_doctor_check_remote() {
    local f meta name pid
    for f in "$SESSIONS_ROOT"/*/.cs/local/remote.pid; do
        [ -e "$f" ] || continue
        meta="${f%/local/remote.pid}"
        name="$(basename "$(dirname "$meta")")"
        if pid=$(_remote_server_pid "$meta" "$name"); then
            _doctor_ok "Remote: $name is served by claude remote-control (PID $pid)"
            continue
        fi
        pid=$(head -n 1 "$f" 2>/dev/null | tr -d '[:space:]') || pid=""
        if rm -f "$f" 2>/dev/null && [ ! -e "$f" ]; then
            _doctor_warn "Remote: $name's .cs/local/remote.pid named PID ${pid:-(none)}, which is no longer $name's claude remote-control server, and nothing removed it when that server ended; removed it now."
        else
            _doctor_warn "Remote: $name's .cs/local/remote.pid named PID ${pid:-(none)}, which is no longer $name's claude remote-control server, and could not be removed: $f"
        fi
    done
}

# Spawn hygiene, all best-effort warnings:
#   - .seed.stale and .brief.md.stale files accumulate in .spawn/ (the launch
#     path sets aged-out seeds aside but never deletes them),
#   - a cs -spawn killed before it published leaves its .<name>.seed.XXXXXX
#     staging file, which no launch reads and nothing else removes,
#   - an open killed outright leaves the seed it claimed under
#     .<name>.seed.claim.<pid>, which no later open reads,
#   - a pending .seed for a session that does not exist blocks re-spawning
#     that name until it is removed,
#   - a spawned-by pointer at a deleted session sends the drain notify nowhere,
#   - a tmux session named 'cs' without the @cs_managed stamp is one cs -spawn
#     will refuse to reuse.
_doctor_check_spawn() {
    local spawn_dir="$SESSIONS_ROOT/.spawn"
    local stale=() orphan=() dangling=() abandoned=() clean=1
    local f name suffix now

    if [ -d "$spawn_dir" ]; then
        # The aged-out suffixes are the .stale ones in cs -spawn's own list.
        for suffix in $(_spawn_staging_suffixes); do
            case "$suffix" in *.stale) ;; *) continue ;; esac
            for f in "$spawn_dir"/*"$suffix"; do
                [ -e "$f" ] || continue
                stale+=("$(basename "$f")")
            done
        done
        for f in "$spawn_dir"/*.seed; do
            [ -e "$f" ] || continue
            name=$(basename "$f" .seed)
            is_session_dir "$SESSIONS_ROOT/$name" || orphan+=("$name")
        done
        # A spawn runs for well under a minute; an older staging file is one
        # whose spawn was killed before it published.
        now=$(date +%s)
        for f in "$spawn_dir"/.*.seed.??????; do
            [ -e "$f" ] || continue
            [ $(( now - $(_epoch_mtime "$f") )) -gt 60 ] || continue
            abandoned+=("$(basename "$f")")
        done
        # A claim is held by an open still at the consent ask while its pid
        # runs; once the pid is gone, nothing puts the seed back.
        for f in "$spawn_dir"/.*.seed.claim.[0-9]*; do
            [ -e "$f" ] || continue
            kill -0 "${f##*.}" 2>/dev/null && continue
            abandoned+=("$(basename "$f")")
        done
    fi
    if [ ${#abandoned[@]} -gt 0 ]; then
        _doctor_warn "Spawn staging: ${#abandoned[@]} file(s) left in .spawn/ by an interrupted cs -spawn or open (never read; safe to delete): ${abandoned[*]}"
        clean=0
    fi
    if [ ${#stale[@]} -gt 0 ]; then
        _doctor_warn "Spawn seeds: ${#stale[@]} aged-out .stale file(s) in .spawn/ (nothing prunes them; safe to delete): ${stale[*]}"
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
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_warn "Hook paths: jq not installed; $settings could not be read"
        return
    fi
    if ! _doctor_settings_parse_ok "$settings"; then
        _doctor_fail "Hook paths: cannot read $settings (invalid JSON)"
        return
    fi
    local commands
    if ! commands=$(jq -r "$_DOCTOR_JQ_HOOKS"' cs_hooks | .command | strings' "$settings" 2>/dev/null); then
        _doctor_fail "Hook paths: cannot read the hook events in $settings"
        return
    fi
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
        # Ask git for the path so both sides of the comparison come from the
        # same binary; a shell's own spelling of the directory need not match
        # git's.
        d_real=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) \
            || d_real=$(cd -- "$d" 2>/dev/null && pwd -P || echo "$d")
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
            _doctor_warn "Worktrees: $name branch $pinned is fully merged; retire it with: /finish ${name#*@} in $base_name"
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
    # Autosave is per-conversation: refs/worktree/cs/session/<uuid>, keyed on
    # the session_id of the conversation that made the edit. The caller's own
    # id comes first: .cs/local/state holds one id per checkout, rebound by the
    # lead only, so a teammate would be judged by the lead's ref. The recorded
    # id covers a plain shell in the session; CS_CLAUDE_SESSION_ID is the
    # launch id and goes stale after the first /clear, so it comes last.
    local uuid ref=""
    uuid="${CLAUDE_CODE_SESSION_ID:-}"
    [ -n "$uuid" ] || uuid=$(_read_local_state "${CLAUDE_SESSION_META_DIR:-$dir/.cs}/local/state" claude_session_id)
    [ -n "$uuid" ] || uuid="${CS_CLAUDE_SESSION_ID:-}"
    if [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        ref="refs/worktree/cs/session/$uuid"
    fi
    local shadow_sha=""
    [ -n "$ref" ] && shadow_sha=$(git -C "$dir" show-ref --verify "$ref" 2>/dev/null | awk '{print $1}' || true)
    # No ref is not evidence of a broken hook: autosave fires on Edit/Write
    # only, and SessionEnd deletes a conversation's ref on a clean /clear, so a
    # dirty tree with no ref is the normal state before the first Edit/Write.
    # What doctor can still check is that the hook which would write it is
    # registered: the file and registration rows enumerate what IS deployed or
    # registered, so a hook missing from both is invisible to them. An absent
    # or unreadable settings file is reported by those rows already.
    if [ -z "$ref" ]; then
        _doctor_ok "Shadow ref: no conversation id to check"
    elif [ -n "$shadow_sha" ]; then
        local ts now age
        ts=$(git -C "$dir" log -1 --format=%ct "$shadow_sha" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - ts))
        _doctor_ok "Shadow ref: $ref present (${age}s old)"
    else
        local settings="${CS_CLAUDE_DIR:-$HOME/.claude}/settings.json" commands
        if [ -f "$settings" ] && command -v jq >/dev/null 2>&1 && _doctor_settings_parse_ok "$settings"; then
            # A registration counts only if it runs the hook on both Write and
            # Edit (the hook exits at once for any other tool) and the command
            # is the hook itself, not a script whose name merely ends the same
            # way. The matcher is a regex, as Claude Code reads it; an empty or
            # "*" matcher covers every tool. An invalid regex counts as no
            # match for its own entry only, since a registration under it
            # cannot fire; the entries after it are still read. As for every
            # hook doctor reads, only the objects in the lists are walked.
            if ! commands=$(jq -r '
                objects | .hooks | objects | .PostToolUse | arrays | .[] | objects
                | select((.matcher // "") as $m
                    | $m == "" or $m == "*"
                      or (try (("Write" | test("^(" + $m + ")$")) and ("Edit" | test("^(" + $m + ")$"))) catch false))
                | .hooks | arrays | .[] | objects | .command | strings
                | select(test("(^|[ /])autosave-commits\\.sh$"))
            ' "$settings" 2>/dev/null); then
                _doctor_warn "Shadow ref: cannot read the PostToolUse hooks in $settings; autosave's registration unknown"
                return
            fi
            if [ -z "$commands" ]; then
                _doctor_warn "Shadow ref: autosave-commits.sh is not registered for PostToolUse on Write and Edit in $settings; edits are not snapshotted"
                return
            fi
        fi
        _doctor_ok "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)"
    fi
}

_doctor_check_claude_audit() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    if [ ! -f "$settings" ]; then
        _doctor_warn "Audit: $settings not found"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_warn "Audit: jq not installed; $settings could not be read"
        return
    fi
    if ! _doctor_settings_parse_ok "$settings"; then
        _doctor_fail "Audit: cannot read $settings (invalid JSON)"
        return
    fi
    # Hooks are counted as cs_hooks walks them, one per hook object.
    local counts hooks_count mcps_count perms_count env_count
    if ! counts=$(jq -r "$_DOCTOR_JQ_HOOKS"'
        "\([cs_hooks] | length) " +
        "\(.mcpServers // {} | length) " +
        "\(((.permissions.allow // []) + (.permissions.deny // [])) | length) " +
        "\(.env // {} | length)"
    ' "$settings" 2>/dev/null); then
        _doctor_warn "Audit: cannot count the hooks, MCPs, permission rules and env vars in $settings"
        return
    fi
    read -r hooks_count mcps_count perms_count env_count <<< "$counts"
    _doctor_ok "Audit: ${hooks_count} hooks, ${mcps_count} MCPs, ${perms_count} perm rules, ${env_count} env vars in settings.json"
}

# Twin: _statusline_chains_to_cs in install.sh.in.
# Follows a bare path (~-prefixed or absolute) with optional arguments; interpreters, quoted paths and $HOME fall through to the doctor's hedged WARN.
_statusline_chains_to_cs() {
    local file rest
    read -r file rest <<< "$1"
    file="${file/#\~/$HOME}"
    [ -f "$file" ] && [ -r "$file" ] && grep -qF -- cs-statusline "$file" 2>/dev/null
}

_doctor_statusline_caps_row() {
    # The rounded caps are drawn only once this machine has answered
    # the font question; until then the bar shows square ends.
    local caps_file caps=""
    caps_file="$(_statusline_caps_file)"
    [ -f "$caps_file" ] && [ -r "$caps_file" ] && { IFS= read -r caps < "$caps_file"; } 2>/dev/null
    case "$caps" in
        on)  _doctor_ok "Statusline caps: rounded (this machine's font has the Powerline caps)" ;;
        off) _doctor_ok "Statusline caps: square (answered off; cs -statusline caps ask to revisit)" ;;
        *)   _doctor_warn "Statusline caps: square until answered — run: cs -statusline caps ask" ;;
    esac
}

_doctor_check_statusline() {
    local claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    local settings="$claude_dir/settings.json"
    local cmd=""
    if [ -f "$settings" ]; then
        cmd=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null) || cmd=""
    fi
    # cs-statusline is the only writer of .cs/local/context-pct, and two gates
    # read it: the Stop hook's rotation nudge and the queue drain's context
    # circuit breaker. Both skip silently when the file is absent, so anything
    # other than cs-statusline leaves them inert with nothing said. Report that
    # as a WARN rather than a clean OK — the gates being off is the news, the
    # statusline itself is genuinely optional.
    local gating="context-pct is never written, so the rotation nudge and the queue context breaker stay inert"
    if [ -z "$cmd" ]; then
        _doctor_warn "Statusline: not registered — $gating (enable with: cs -statusline enable)"
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
            _doctor_statusline_caps_row
            ;;
        *)
            # A foreign command can chain to cs-statusline (a bridge that runs
            # the original), so inside a session the file itself decides: a
            # context-pct inside the heartbeat window means the gates are fed.
            # An empty or non-numeric file feeds no gate, however fresh.
            local meta="${CLAUDE_SESSION_META_DIR:-}" now age reading="" chains=""
            _statusline_chains_to_cs "$cmd" && chains=1
            now=$(date +%s)
            [ -z "$meta" ] || reading=$(tr -d '[:space:]' < "$meta/local/context-pct" 2>/dev/null) || reading=""
            case "$reading" in ''|*[!0-9]*) reading="" ;; esac
            if [ -n "$reading" ] && session_heartbeat_alive "$meta" "$now"; then
                age=$(( (now - $(_epoch_mtime "$meta/local/context-pct")) / 60 ))
                [ "$age" -ge 0 ] || age=0
                _doctor_ok "Statusline: context-pct written $age min ago through $cmd"
            elif [ -n "$chains" ]; then
                _doctor_ok "Statusline: $cmd chains to cs-statusline"
            else
                _doctor_warn "Statusline: using a non-cs status line ($cmd) — $gating, unless it chains to cs-statusline"
            fi
            [ -z "$chains" ] || _doctor_statusline_caps_row
            ;;
    esac
}

# The Ctrl+X bindings the installer offers: the answer this
# machine gave, and whether keybindings.json still holds cs's keys. Not asked
# and declined are healthy; a key the user binds to something else (or a bare
# ctrl+x a chord would shadow), a yes whose keys are gone, sit outside the
# context Claude Code wants them in, or are still an earlier cs's Option+1 /
# Option+2, and a file Claude Code cannot read either are warnings. A file
# that holds every cs key but has one outside its context is a warning
# whatever the answer: the installer rewrites the file only on a recorded
# yes, so under any other answer the advice is the move to make by hand.
_doctor_check_rotate_wrap_keys() {
    local file answer_file answer status state key action prefix retired bound=0 misplaced=0 total=0 commands_bound=0
    file="$(_cs_keybindings_file)"
    answer_file="$(_cs_rotate_wrap_keys_answer_file)"
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_warn "Rotate/wrap keys: jq not installed; $file could not be read"
        return
    fi
    if [ -e "$file" ] && ! _cs_keybindings_shape_ok "$file"; then
        _doctor_warn "Rotate/wrap keys: $file is unparseable (not JSON with a \"bindings\" array)"
        return
    fi
    if [ -e "$file" ]; then
        status=$(_cs_rotate_wrap_keys_status < "$file") || status=""
    else
        status=$(printf '{"bindings":[]}\n' | _cs_rotate_wrap_keys_status) || status=""
    fi
    while IFS=$'\t' read -r state key action prefix; do
        [ -n "$state" ] || continue
        total=$((total + 1))
        case "$state" in
            bound) bound=$((bound + 1)) ;;
            misplaced) misplaced=$((misplaced + 1)) ;;
        esac
    done <<< "$status"
    answer=$(cat "$answer_file" 2>/dev/null) || answer=""
    if [ "$total" -gt 0 ] && [ "$((bound + misplaced))" = "$total" ]; then
        while IFS=$'\t' read -r state key action prefix; do
            [ "$state" = misplaced ] || continue
            if [ "$answer" = yes ]; then
                _doctor_warn "Rotate/wrap keys: $key is bound outside the $action context in $file (run cs -update to move it)"
            else
                _doctor_warn "Rotate/wrap keys: $key is bound outside the $action context in $file (move it into a block with \"context\": \"$action\")"
            fi
        done <<< "$status"
        retired=$(_cs_keybindings_held "$CS_RETIRED_OPTION_KEYS" < "$file") || retired=""
        if [ -n "$retired" ]; then
            _doctor_warn "Rotate/wrap keys: $retired still hold cs's earlier bindings in $file (run cs -update to remove them)"
        elif [ "$misplaced" = 0 ]; then
            _doctor_ok "Rotate/wrap keys: bound (Ctrl+X R runs /rotate, Ctrl+X W runs /wrap, Ctrl+X 1 and Ctrl+X 2 press the cs band)"
        fi
        return
    fi
    case "$answer" in
        yes)
            while IFS=$'\t' read -r state key action prefix; do
                case "$state $key" in
                    "bound ctrl+x r"|"bound ctrl+x w") commands_bound=$((commands_bound + 1)) ;;
                esac
                case "$state" in
                    conflict)
                        if [ -n "$prefix" ]; then
                            _doctor_warn "Rotate/wrap keys: conflict on $key ($prefix is bound to $action in $file)"
                        else
                            _doctor_warn "Rotate/wrap keys: conflict on $key (bound to $action in $file)"
                        fi
                        ;;
                    free) _doctor_warn "Rotate/wrap keys: $key not bound (run cs -update to bind it)" ;;
                    misplaced) _doctor_warn "Rotate/wrap keys: $key is bound outside the $action context in $file (run cs -update to move it)" ;;
                esac
            done <<< "$status"
            # With /rotate and /wrap on their chords, the next update takes
            # cs's Option keys back whatever a band chord holds.
            if [ "$commands_bound" = 2 ]; then
                retired=$(_cs_keybindings_held "$CS_RETIRED_OPTION_KEYS" < "$file") || retired=""
                if [ -n "$retired" ]; then
                    _doctor_warn "Rotate/wrap keys: $retired still hold cs's earlier bindings in $file (run cs -update to remove them)"
                fi
            fi
            ;;
        no)
            _doctor_ok "Rotate/wrap keys: declined (to be asked again, remove $answer_file and run cs -update in a terminal)"
            ;;
        *)
            _doctor_ok "Rotate/wrap keys: not asked (run cs -update in a terminal to be asked)"
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

# A narrative past CS_NARRATIVE_MAX_BYTES is what `cs -narrative rotate` exists
# for; doctor only reports, it never rotates.
_doctor_check_narrative_size() {
    local dir="$CLAUDE_SESSION_META_DIR/memory"
    local max over=0 f sz
    max=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
    for f in "$dir"/narrative*.md; do
        [ -f "$f" ] || continue
        sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
        if [ "$sz" -gt "$max" ]; then
            # .cs/memory is tracked, so a clone chooses the file name.
            _doctor_warn "Narrative: $(_cs_plain_name "$(basename "$f")" 160) is $((sz / 1024)) KB (budget $((max / 1024)) KB) — run cs -narrative rotate"
            over=$((over + 1))
        fi
    done
    [ "$over" -gt 0 ] || _doctor_ok "Narrative: all within the $((max / 1024)) KB budget"
}

# Cross-check the session UUID recorded in .cs/local/state against
# the live $CLAUDE_CODE_SESSION_ID (set by Claude Code inside its own session).
# A mismatch means the running claude conversation is not the one cs thinks
# it is — usually because the user launched claude outside cs in this dir,
# or because migrate_session backfilled a UUID after Claude Code had already
# resolved its own session ID. The recorded UUID is the source of truth for
# cs and hooks; doctor surfaces the divergence so the user can decide whether
# to relaunch via cs or accept the drift.
# cs's settings files, as the loader bin/cs ran when it started read them
# (with this session's file when CLAUDE_SESSION_DIR names one): how many
# settings each holds, every line the readers skip and why, and every value
# the environment hides, which no edit of the file can change.
_doctor_check_config() {
    local mlabel slabel row rec key scope n text why v
    _config_label "$_CS_CONFIG_MACHINE"
    mlabel=$_CONFIG_LABEL
    _config_label "" "$(_config_session_name)"
    slabel=$_CONFIG_LABEL
    if [ ! -f "$_CS_CONFIG_MACHINE" ]; then
        row="no $mlabel (cs -config set keeps one)"
    elif [ "$_CS_CONFIG_COUNT_M" = 1 ]; then
        row="1 setting in $mlabel"
    else
        row="$_CS_CONFIG_COUNT_M settings in $mlabel"
    fi
    [ -z "$_CS_CONFIG_SESSION" ] || row="$row, $_CS_CONFIG_COUNT_S in this session's"
    _doctor_ok "config: $row"
    while IFS=$'\t' read -r scope n text why; do
        [ -n "$scope" ] || continue
        if [ "$scope" = M ]; then v=$mlabel; else v=$slabel; fi
        _doctor_warn "config: $v line $n: $text: $why (skipped)"
    done <<< "$_CS_CONFIG_IGNORED"
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        key=${rec%%|*}
        cs_config_source "$key"
        [ "$_CS_CFG_SOURCE" = shell ] || continue
        if _config_listed "$_CS_CFG_READ_S" "$key"; then
            v="_CS_CFG_S_$key"
            _doctor_info "config: $key=${!key//[[:cntrl:]]/?} in your environment hides ${!v} in $slabel"
        elif _config_listed "$_CS_CFG_READ_M" "$key"; then
            v="_CS_CFG_M_$key"
            _doctor_info "config: $key=${!key//[[:cntrl:]]/?} in your environment hides ${!v} in $mlabel"
        fi
    done
}

# Every place cs changes what the model sees, with the switch that turns
# it off. The consent rule covers what the user looks at — status line, titles —
# but a hook that injects context installs silently, so this is where that
# authority is made visible. State is read live, not from config: a switch that
# is set shows the injection as off.
_doctor_check_hook_authority() {
    echo ""
    echo "  Authority — instructions cs adds to the model's context:"
    local disabled_all=""
    if [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -f "${CLAUDE_SESSION_META_DIR}/local/disabled" ]; then
        disabled_all=1
    fi
    # The hooks read their switch as `= "1"`, so the row must too: an exported
    # 0 leaves the injection on and has to read as on here. A row whose switch
    # is a setting names where its value comes from, when something sets it.
    _doctor_authority_row() {  # label hook switch value [setting]
        local state="on" from=""
        if [ -n "$disabled_all" ] || [ "$4" = "1" ]; then state="off"; fi
        if [ -n "${5:-}" ]; then
            cs_config_source "$5"
            case "$_CS_CFG_SOURCE" in
                shell) from=" (your environment)" ;;
                session) from=" (this session's config)" ;;
                machine) from=" (this machine's config)" ;;
            esac
        fi
        printf "    %-4s %-22s %-20s off: %s%s\n" "$state" "$1" "$2" "$3" "$from"
    }
    _doctor_authority_row "grounding"     "scope-prompt"       'CS_SCOPE_DISABLE=1'             "${CS_SCOPE_DISABLE:-}" CS_SCOPE_DISABLE
    _doctor_authority_row "clarify"       "scope-prompt"       'CS_CLARIFY_DISABLE=1'           "${CS_CLARIFY_DISABLE:-}" CS_CLARIFY_DISABLE
    _doctor_authority_row "date reminder" "scope-prompt"       'CS_DATE_REMINDER_DISABLE=1'     "${CS_DATE_REMINDER_DISABLE:-}" CS_DATE_REMINDER_DISABLE
    _doctor_authority_row "objective"     "scope-prompt"       'CS_OBJECTIVE_CAPTURE_DISABLE=1' "${CS_OBJECTIVE_CAPTURE_DISABLE:-}" CS_OBJECTIVE_CAPTURE_DISABLE
    _doctor_authority_row "rewrite"       "prompt-rewriter"    'CS_REWRITE_DISABLE=1'           "${CS_REWRITE_DISABLE:-}" CS_REWRITE_DISABLE
    _doctor_authority_row "narrative"     "narrative-reminder" '.cs/local/disabled'             ""
    _doctor_authority_row "council nudge" "narrative-reminder" '.cs/local/disabled or uninstall the plugin' ""
    _doctor_authority_row "ctx warning"   "narrative-reminder" 'CS_CTX_WARN_CTX=101'            ""
    _doctor_authority_row "rotate nudge"  "narrative-reminder" 'CS_ROTATE_NUDGE_CTX=101'        ""
    _doctor_authority_row "subagent ctx"  "subagent-context"   '.cs/local/disabled'             ""
    _doctor_authority_row "session ctx"   "session-start"      '.cs/local/disabled'             ""
    # Local instructions remain in the prompt even when session hooks are disabled.
    disabled_all=""
    local diagrams_off=1
    local dir="${CLAUDE_SESSION_DIR:-$PWD}"
    if [ -n "$dir" ] && [ -f "$dir/CLAUDE.local.md" ] && awk '
        /^<!-- cs:mermaid-diagrams -->$/ { section=1; next }
        section == 1 && /^## Diagrams$/ { section=2; next }
        /^<!-- cs:/ || /^## / { section=0 }
        section && /[^[:space:]]/ && !/^[[:space:]]*(#|<!--)/ { prose=1 }
        END { exit !prose }
    ' "$dir/CLAUDE.local.md"; then
        diagrams_off=""
    fi
    _doctor_authority_row "diagrams" "CLAUDE.local.md" 'delete the prose under cs:mermaid-diagrams' "$diagrams_off"
    echo "    .cs/local/disabled turns the hook rows off; CLAUDE.local.md still applies."
}

# setup_merge_attributes writes the per-clone merge driver with `|| true`, so a
# clone where that write failed keeps a .gitattributes that says merge=ours with
# nothing behind it, and MEMORY.md text-merges on the next pull. The driver is
# deliberately per-clone and never global — cs does not write to ~/.gitconfig —
# so a clone cs has not launched in is out of reach; this names the one it can see.
_doctor_check_merge_driver() {
    local dir="${CLAUDE_SESSION_DIR:-}"
    [ -n "$dir" ] || return 0
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    grep -q 'merge=ours' "$dir/.gitattributes" 2>/dev/null || return 0
    if [ "$(git -C "$dir" config --get merge.ours.driver 2>/dev/null)" = "true" ]; then
        _doctor_ok "Merge driver: merge.ours.driver set for this clone"
    else
        _doctor_warn "Merge driver: merge.ours.driver not set in this clone — MEMORY.md will text-merge on pull. Launch the session once with cs, or: git config merge.ours.driver true"
    fi
}

# The stamp an open trusts to skip the one-time migration phases, judged by
# the same probe the open runs (_migration_stamp_state). Read-only. A feature
# worktree never runs the migration, so it has no stamp to report.
_doctor_check_migration_stamp() {
    local dir="${CLAUDE_SESSION_DIR:-}" state
    [ -n "$dir" ] || return 0
    # A worktree open never migrates, so never stamps. cs_base or task_branch
    # marks one; task_branch is the key the worktree open itself reads.
    if [ -n "$(_read_local_state "$dir/.cs/local/state" cs_base)" ] \
        || [ -n "$(_read_local_state "$dir/.cs/local/state" task_branch)" ]; then
        return 0
    fi
    state=$(_migration_stamp_state "$dir" "$(cs_actor_raw "$dir" "$dir/.cs")")
    case "$state" in
        fresh)
            _doctor_ok "Migration stamp: current for cs $VERSION; opens skip the one-time migration checks. To force them: rm .cs/local/migrated" ;;
        narrative)
            _doctor_ok "Migration stamp: current but for MEMORY.md; the next open re-checks the narrative pointer and restamps. To force every check: rm .cs/local/migrated" ;;
        *)
            _doctor_ok "Migration stamp: stale (${state#stale: }); the next open runs the full migration and restamps. Reset by hand: rm .cs/local/migrated" ;;
    esac
}

# `cs <base> -integrate-feature` takes <git-dir>/cs/integrate.lock for the
# length of a landing, and the autosave hook skips its snapshot while it
# exists. A lock left behind by a killed integrate silences this checkout's
# autosave with nothing on screen to say why, so name it and the one command
# that clears it.
_doctor_check_integrate_lock() {
    local dir="${CLAUDE_SESSION_DIR:-}"
    [ -n "$dir" ] || return 0
    local git_dir lock
    git_dir=$(_git_path_abs "$dir" --git-dir) || return 0
    lock="$git_dir/cs/integrate.lock"
    [ -d "$lock" ] || return 0
    # The integrate writes its pid into the lock; that pid is the evidence, not
    # a process listing, which would answer for any integrate on the machine.
    #
    # A lock with no pid is not a stale lock. The autosave hook takes this same
    # directory and records nothing in it, for as long as a snapshot takes (its
    # registration allows ten seconds), so a doctor run inside that window sees
    # exactly this. Removing it would not stop that worker either: it would let
    # an integrate take the directory while autosave keeps committing, which is
    # the interleaving the lock exists to prevent. So an absent pid is reported
    # as a thing cs cannot judge, and carries no removal command.
    # (The worker cannot simply record its own pid: on stock bash 3.2 `$$`
    # inside the backgrounded subshell is the parent, which has already exited,
    # and BASHPID does not exist there — cs would write a pid that is dead on
    # arrival and doctor would call a live worker stale.)
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    case "$pid" in
        *[!0-9]*) pid="" ;;
    esac
    pid="${pid#"${pid%%[!0]*}"}"
    # kill -0, not ps: kill(2) sees a process that a restricted /proc hides
    # from ps, and its errno tells a holder owned by another user (EPERM) from
    # a pid that is gone (ESRCH). Only ESRCH is evidence of absence; anything
    # else the check cannot read is unknown, and an unknown must not come with
    # removal advice. LC_ALL=C pins the message kill prints, which is the only
    # channel for the errno. env runs the kill on PATH (/bin/kill on macOS)
    # with that locale in its own environment, so the shell never changes its
    # own locale in this forked copy, which can crash a bash linked against
    # libintl. That kill prints "kill: <pid>: No such process" or "kill:
    # <pid>: Operation not permitted" and exits 1, and refuses a pid it cannot
    # parse with "kill: illegal process id: <pid>", which is unknown. A number
    # past the pid range never reaches kill: procps kill on Linux would
    # truncate it to a pid_t and answer for another process (ESRCH for most
    # values, and 4294967297 is pid 1, which is held), so the range is
    # screened by cs's own rule first and the number is unknown.
    local verdict="unrecorded" why=""
    if [ -n "$pid" ]; then
        if ! _cs_pid_in_range "$pid"; then
            verdict="unknown" why="no process can have that pid"
        elif why=$(env LC_ALL=C kill -0 "$pid" 2>&1); then
            verdict="held"
        else
            case "$why" in
                *"No such process"*)        verdict="stale" ;;
                *"Operation not permitted"*) verdict="eperm" ;;
                *)                           verdict="unknown" why="${why#kill: }" ;;
            esac
        fi
    fi
    case "$verdict" in
        held)    _doctor_ok "Integrate lock: $lock held by a running integrate (pid $pid)" ;;
        eperm)   _doctor_ok "Integrate lock: $lock held by a running integrate (pid $pid; signalling it is not permitted here, which is a process that exists)" ;;
        unknown) _doctor_warn "Integrate lock: $lock records pid $pid and cs cannot tell whether it is running ($why)" ;;
        # ESRCH is absence only in this process's pid namespace, and pids are
        # recycled, so the removal stays conditional on what the person can see.
        stale)   _doctor_warn "Integrate lock: $lock records pid $pid, which this process cannot see; the lock is probably stale. Autosave skips while it exists. Once nothing is using this checkout, clear it with: rm -r \"$lock\"" ;;
        *)       _doctor_warn "Integrate lock: $lock has no holder pid, so cs cannot tell an active autosave or integrate from a lock left behind. Autosave skips while it exists. Recheck once nothing is working in this checkout." ;;
    esac
}

_doctor_check_session_id_match() {
    local state="$CLAUDE_SESSION_META_DIR/local/state"
    local recorded
    recorded=$(_read_local_state "$state" claude_session_id)
    if [ -z "$recorded" ]; then
        _doctor_warn "Session UUID: not recorded in .cs/local/state — the next cs launch binds the folder's newest conversation, or starts one and records it"
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

# A mod (cs, cs-update; cs-mermaid and cs-panel write no heartbeat) is a Claude Code function-hooks plugin the
# installer deploys under ~/.claude/skills. Absent, it is not news. Present, the
# row reads the heartbeat the mod writes when Claude Code loads it, never the
# directory: the loader sits behind CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, which a
# cs launch exports and CS_NO_FUNCTION_HOOKS withholds, and a managed machine's
# policy can load a mod and never run it, so presence proves nothing.
# The heartbeat is per session, hence the session guard around the call. A
# teammate process with the flag on writes it too, so OK says the mod ran in
# this directory, not that the lead's shell carries the flag.
_doctor_check_mod() {  # mod name
    local mod="$1" claude_dir="${CS_CLAUDE_DIR:-$HOME/.claude}"
    [ -d "$claude_dir/skills/$mod" ] || return 0
    local beat="$CLAUDE_SESSION_META_DIR/local/$mod.heartbeat" stamp=""
    if [ -f "$beat" ] && [ -r "$beat" ]; then
        { IFS= read -r stamp < "$beat"; } 2>/dev/null || stamp=""
    fi
    if [ -n "$stamp" ]; then
        _doctor_ok "$mod mod: last ran $stamp in this session"
    else
        _doctor_warn "$mod mod: installed but has not run in this session — no cs launch since the install, function hooks withheld (CS_NO_FUNCTION_HOOKS, or CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0), or Claude Code no longer loads mods behind that flag"
    fi
}

run_doctor() {
    local DOCTOR_FAIL=0
    local DOCTOR_WARN=0

    echo "cs doctor - running health checks"
    echo ""

    _doctor_check_settings_valid
    _doctor_check_keychain
    _doctor_check_hooks_registered
    _doctor_check_hook_files_executable
    _doctor_check_hook_drift
    _doctor_check_tui_build
    _doctor_check_deployed_version
    _doctor_check_settings_hooks_resolve
    _doctor_check_claude_audit
    _doctor_check_statusline
    _doctor_check_subagent_statusline
    _doctor_check_rotate_wrap_keys
    _doctor_check_iterm2
    _doctor_check_spawn
    _doctor_check_remote
    _doctor_check_config
    _doctor_check_hook_authority

    if [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -d "${CLAUDE_SESSION_META_DIR:-}" ]; then
        _doctor_check_shadow_ref
        _doctor_check_merge_driver
        _doctor_check_migration_stamp
        _doctor_check_integrate_lock
        _doctor_check_worktrees
        _doctor_check_auto_memory
        _doctor_check_narrative_size
        _doctor_check_session_id_match
        _doctor_check_token_cost
        _doctor_check_mod cs
        _doctor_check_mod cs-update
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
