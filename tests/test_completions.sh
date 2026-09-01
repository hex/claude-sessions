#!/usr/bin/env bash
# ABOUTME: Guards against drift between bin/cs's command dispatch and the shell completions
# ABOUTME: Every top-level -command in bin/cs must appear in completions/_cs and completions/cs.bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_FILE="$SCRIPT_DIR/../bin/cs"
SECRETS_FILE="$SCRIPT_DIR/../bin/cs-secrets"
ZSH_COMP="$SCRIPT_DIR/../completions/_cs"
BASH_COMP="$SCRIPT_DIR/../completions/cs.bash"
# The session dispatch is read from its lib fragment, not the built bin/cs: the
# build concatenates every fragment, so -msg/-queue/-tag's own argument parsers
# contribute their flags to any `while [ $# -gt 0 ]` range taken over bin/cs.
# CI already pins bin/cs as an exact build of lib/, so the two cannot diverge.
MAIN_LIB="$SCRIPT_DIR/../lib/99-main.sh"

# Extract single-dash top-level command tokens from the main dispatch case
# (the 8-space-indented arms only, so nested case arms like -update's are excluded).
# Arms tagged `# hidden` are plumbing invoked by scripts rather than typed by a
# user, so they are exempt from the requirement to appear in the completions.
dispatch_commands() {
    awk '/# Handle subcommands \(with - prefix\)/,/^    esac/' "$CS_FILE" \
        | grep -v '# hidden' \
        | grep -oE '^ {8}-[a-zA-Z|-]+\)' \
        | tr -d ' )' \
        | tr '|' '\n' \
        | grep -E '^-[a-z]' \
        | grep -vE '^--' \
        | grep -v '^-\*' \
        | sort -u
}

test_dispatch_extraction_is_sane() {
    local cmds
    cmds=$(dispatch_commands)
    assert_output_contains "$cmds" "-adopt" "extraction should find -adopt" || return 1
    assert_output_contains "$cmds" "-whoami" "extraction should find -whoami" || return 1
}

# Extract secrets subcommand tokens from bin/cs-secrets' argument parser: the
# single combined arm (set|store|...|backend), plus age, which takes its own arm.
secrets_subcommands() {
    {
        grep -oE '^ +set\|store\|[a-z|-]+\)' "$SECRETS_FILE" \
            | tr -d ' )' \
            | tr '|' '\n'
        echo "age"
    } | grep -E '^[a-z]' | sort -u
}

# Both completion scripts shell out to `cs`, so a functional test has to shadow
# the installed cs with the one just built from lib/.
put_built_cs_on_path() {
    mkdir -p "$TEST_TMPDIR/bin"
    ln -sf "$(cd "$(dirname "$CS_BIN")" && pwd)/$(basename "$CS_BIN")" "$TEST_TMPDIR/bin/cs"
    PATH="$TEST_TMPDIR/bin:$PATH"
}

# First-argument completion: `cs <word>`. Thin wrapper over the general
# word-list driver below (COMP_WORDS=(cs "$word"), COMP_CWORD=1). The script
# under test is passed in so a pre-fix copy can be checked against the same
# assertions.
bash_candidates_for() {  # script, word
    bash_candidates_words "$1" cs "$2"
}

# Drive bash completion with an explicit word list (cs first; the final element
# is the word being completed). COMP_CWORD points at that final element.
bash_candidates_words() {  # script word...
    local script="$1"; shift
    bash --norc --noprofile -c '
        PATH="$1:$PATH"
        source "$2"
        shift 2
        COMP_WORDS=("$@")
        COMP_CWORD=$(( $# - 1 ))
        _cs_completions
        printf "%s\n" "${COMPREPLY[@]}"
    ' _ "$TEST_TMPDIR/bin" "$script" "$@" 2>/dev/null
}

# Drive zsh completion with an explicit word list (cs first; the final element
# is the word being completed). CURRENT points at that final element.
zsh_candidates_words() {  # word...
    zsh -f -c '
        PATH="$1:$PATH"; comp="$2"; shift 2
        _describe() { local arr=${@[-1]}; print -rl -- ${(P)arr} }
        words=("$@")
        CURRENT=$#
        source "$comp"
    ' _ "$TEST_TMPDIR/bin" "$ZSH_COMP" "$@" 2>/dev/null | sed 's/:.*//'
}

test_bash_completion_offers_a_symlinked_session() {
    create_test_session "real-session" >/dev/null
    link_test_session "linked-session"
    put_built_cs_on_path

    local out
    out=$(bash_candidates_for "$BASH_COMP" "linked")
    assert_candidate "$out" "linked-session" "bash must offer a symlinked session" || return 1
}

# Proves the assertion above has teeth: the enumeration this replaced cannot pass it.
test_bash_completion_before_the_fix_missed_symlinked_sessions() {
    create_test_session "real-session" >/dev/null
    link_test_session "linked-session"
    put_built_cs_on_path

    local old_script="$TEST_TMPDIR/cs.bash.pre-fix"
    cat > "$old_script" <<'PREFIX'
_cs_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local sessions_root="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
    COMPREPLY=($(compgen -W "$(find "$sessions_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)" -- "$cur"))
}
PREFIX

    local out
    out=$(bash_candidates_for "$old_script" "linked")
    assert_not_candidate "$out" "linked-session" "the pre-fix enumeration is expected to miss symlinks" || return 1
}

# First-argument completion: `cs <word>`. Thin wrapper over the general
# word-list driver above (words=(cs "$word"), CURRENT=2).
zsh_candidates_for_first_word() {  # word
    zsh_candidates_words cs "$1"
}

test_zsh_completion_offers_a_symlinked_session() {
    if ! command -v zsh >/dev/null 2>&1; then
        echo "    (zsh not installed, skipping)"
        return 0
    fi
    create_test_session "real-session" >/dev/null
    link_test_session "linked-session"
    put_built_cs_on_path

    local out
    out=$(zsh_candidates_for_first_word "linked")
    assert_candidate "$out" "linked-session" "zsh must offer a symlinked session" || return 1
}

# An empty first word is the one moment a user is asking "what can I even type
# here", so it must answer with both halves of the answer, not just sessions.
test_bash_completion_offers_sessions_and_flags_on_an_empty_word() {
    create_test_session "real-session" >/dev/null
    put_built_cs_on_path

    local out
    out=$(bash_candidates_for "$BASH_COMP" "")
    assert_candidate "$out" "real-session" "bare TAB must offer sessions" || return 1
    assert_candidate "$out" "-list" "bare TAB must offer flags" || return 1
}

# A word beginning with a dash can only be a flag, so neither script should pay
# to enumerate sessions there. Shadow cs with a recorder and assert it stays
# untouched while a flag is being completed.
recording_cs_on_path() {
    mkdir -p "$TEST_TMPDIR/bin"
    local marker="$TEST_TMPDIR/cs-was-called"
    cat > "$TEST_TMPDIR/bin/cs" <<REC
#!/usr/bin/env bash
echo called >> "$marker"
REC
    chmod +x "$TEST_TMPDIR/bin/cs"
    PATH="$TEST_TMPDIR/bin:$PATH"
    printf '%s' "$marker"
}

# A session name is validated to `^[a-zA-Z0-9._-]+$`, but the completion must not
# mangle one that slips in by hand: an unquoted `COMPREPLY=($(compgen ...))` word-
# splits a spaced name into pieces and glob-expands a name with a star against the
# cwd. Populate COMPREPLY without those expansions instead.
test_bash_completion_does_not_split_a_session_name_with_spaces() {
    mkdir -p "$CS_SESSIONS_ROOT/my session/.cs"
    put_built_cs_on_path

    local out
    out=$(bash_candidates_for "$BASH_COMP" "my")
    assert_candidate "$out" "my session" "a spaced name must stay one candidate" || return 1
    assert_not_candidate "$out" "session" "a spaced name must not split into pieces" || return 1
}

test_bash_completion_does_not_glob_a_session_name_with_a_star() {
    mkdir -p "$CS_SESSIONS_ROOT/star*name/.cs"
    # A decoy file the star would expand to if the name reached the shell unquoted.
    ( cd "$TEST_TMPDIR" && : > "starHITname" )
    put_built_cs_on_path

    local out
    out=$(cd "$TEST_TMPDIR" && bash_candidates_for "$BASH_COMP" "star")
    assert_candidate "$out" 'star*name' "the literal starred name must be the candidate" || return 1
    assert_not_candidate "$out" "starHITname" "completion must not glob cwd files into candidates" || return 1
}

test_bash_completion_does_not_enumerate_when_completing_a_flag() {
    local marker; marker=$(recording_cs_on_path)
    bash_candidates_for "$BASH_COMP" "-" >/dev/null
    assert_file_not_exists "$marker" "bash must not call cs to complete a flag" || return 1
}

test_zsh_completion_does_not_enumerate_when_completing_a_flag() {
    if ! command -v zsh >/dev/null 2>&1; then
        echo "    (zsh not installed, skipping)"
        return 0
    fi
    local marker; marker=$(recording_cs_on_path)
    zsh_candidates_for_first_word "-" >/dev/null
    assert_file_not_exists "$marker" "zsh must not call cs to complete a flag" || return 1
}

test_zsh_completion_offers_sessions_and_flags_on_an_empty_word() {
    if ! command -v zsh >/dev/null 2>&1; then
        echo "    (zsh not installed, skipping)"
        return 0
    fi
    create_test_session "real-session" >/dev/null
    put_built_cs_on_path

    local out
    out=$(zsh_candidates_for_first_word "")
    assert_candidate "$out" "real-session" "bare TAB must offer sessions" || return 1
    assert_candidate "$out" "-list" "bare TAB must offer flags" || return 1
}

# The symlink bug existed because each completion script enumerated sessions in
# its own dialect. Neither should know where sessions live or what marks one.
test_completions_delegate_session_enumeration_to_cs() {
    assert_file_contains "$ZSH_COMP" 'cs -complete sessions' "_cs must ask cs for session names" || return 1
    assert_file_contains "$BASH_COMP" 'cs -complete sessions' "cs.bash must ask cs for session names" || return 1
    assert_file_not_contains "$ZSH_COMP" 'sessions_root' "_cs must not locate the sessions root itself" || return 1
    assert_file_not_contains "$BASH_COMP" 'sessions_root' "cs.bash must not locate the sessions root itself" || return 1
}

test_hidden_commands_are_exempt_from_completion_coverage() {
    local cmds
    cmds=$(dispatch_commands)
    assert_output_not_contains "$cmds" "-complete" "-complete is plumbing and must stay out of the user-facing flag list" || return 1
}

test_secrets_extraction_is_sane() {
    local cmds
    cmds=$(secrets_subcommands)
    assert_output_contains "$cmds" "age" "extraction should find age" || return 1
    assert_output_contains "$cmds" "migrate-backend" "extraction should find migrate-backend" || return 1
    assert_output_contains "$cmds" "export-file" "extraction should find export-file" || return 1
}

test_zsh_completion_covers_all_commands() {
    local missing="" cmd
    for cmd in $(dispatch_commands); do
        if ! grep -qF "'$cmd:" "$ZSH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/_cs missing:$missing"
        return 1
    fi
}

test_bash_completion_covers_all_commands() {
    local missing="" cmd
    for cmd in $(dispatch_commands); do
        if ! grep -qE "[\" ]$cmd[\" ]" "$BASH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/cs.bash missing:$missing"
        return 1
    fi
}

test_zsh_completion_covers_all_secrets_subcommands() {
    local missing="" cmd
    for cmd in $(secrets_subcommands); do
        if ! grep -qF "'$cmd:" "$ZSH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/_cs missing secrets subcommands:$missing"
        return 1
    fi
}

test_bash_completion_covers_all_secrets_subcommands() {
    local missing="" cmd
    for cmd in $(secrets_subcommands); do
        if ! grep -qE "[\" ]$cmd[\" ]" "$BASH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/cs.bash missing secrets subcommands:$missing"
        return 1
    fi
}

# Link a directory outside the sessions root in as a session, the way `cs -adopt`
# does for a repo that lives elsewhere on disk.
link_test_session() {
    local name="$1"
    local target="$TEST_TMPDIR/external/$name"
    mkdir -p "$target/.cs"
    ln -s "$target" "$CS_SESSIONS_ROOT/$name"
}

# `cs -complete` emits one candidate per line, so match whole lines: a substring
# match would let "real-session" satisfy an assertion about "not-a-session", and
# the dot in ".obsidian" would otherwise be read as a regex wildcard.
assert_candidate() {
    local output="$1" name="$2" msg="$3"
    if ! printf '%s\n' "$output" | grep -qxF -- "$name"; then
        echo "  FAIL: $msg"
        echo "    candidates: $(printf '%s' "$output" | tr '\n' ' ')"
        return 1
    fi
}

assert_not_candidate() {
    local output="$1" name="$2" msg="$3"
    if printf '%s\n' "$output" | grep -qxF -- "$name"; then
        echo "  FAIL: $msg"
        echo "    candidates: $(printf '%s' "$output" | tr '\n' ' ')"
        return 1
    fi
}

complete_sessions_output() {
    "$CS_BIN" -complete sessions 2>&1
}

test_complete_sessions_includes_symlinked_session() {
    create_test_session "real-session" >/dev/null
    link_test_session "linked-session"

    local out
    out=$(complete_sessions_output) || {
        echo "  FAIL: cs -complete sessions exited nonzero: $out"
        return 1
    }
    assert_candidate "$out" "linked-session" "a symlinked session must complete" || return 1
    assert_candidate "$out" "real-session" "a plain session must complete" || return 1
}

test_complete_sessions_excludes_directories_without_a_session_marker() {
    create_test_session "real-session" >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/scratch-dir"
    mkdir -p "$CS_SESSIONS_ROOT/.obsidian"

    local out
    out=$(complete_sessions_output) || {
        echo "  FAIL: cs -complete sessions exited nonzero: $out"
        return 1
    }
    assert_candidate "$out" "real-session" "a session with a .cs/ marker must complete" || return 1
    assert_not_candidate "$out" "scratch-dir" "a bare directory is not a session" || return 1
    assert_not_candidate "$out" ".obsidian" "a dotted config directory is not a session" || return 1
}

# Sessions created before the .cs/ layout keep their state beside a root
# CLAUDE.md, and cs still lists them; completion must not lose them.
test_complete_sessions_includes_a_legacy_session() {
    local legacy="$CS_SESSIONS_ROOT/legacy-session"
    mkdir -p "$legacy/logs"
    echo "# Session" > "$legacy/CLAUDE.md"

    local out
    out=$(complete_sessions_output) || {
        echo "  FAIL: cs -complete sessions exited nonzero: $out"
        return 1
    }
    assert_candidate "$out" "legacy-session" "a pre-.cs/ session with a root CLAUDE.md must complete" || return 1
}

# --- Multi-name verbs and -msg/-spawn first-arg completion ---

test_bash_msg_completes_target_session() {
    create_test_session "target-sess" >/dev/null
    put_built_cs_on_path
    local out; out=$(bash_candidates_words "$BASH_COMP" cs -msg "")
    assert_candidate "$out" "target-sess" "cs -msg <TAB> must offer a target session" || return 1
}

test_bash_spawn_completes_session_name() {
    create_test_session "spawn-me" >/dev/null
    put_built_cs_on_path
    local out; out=$(bash_candidates_words "$BASH_COMP" cs -spawn "")
    assert_candidate "$out" "spawn-me" "cs -spawn <TAB> must offer a session name" || return 1
}

test_bash_rm_completes_beyond_first_name() {
    create_test_session "keep-one" >/dev/null
    create_test_session "keep-two" >/dev/null
    put_built_cs_on_path
    local out; out=$(bash_candidates_words "$BASH_COMP" cs -rm keep-one "")
    assert_candidate "$out" "keep-two" "cs -rm <name> <TAB> must offer a second session" || return 1
}

test_bash_archive_completes_beyond_first_name() {
    create_test_session "arch-one" >/dev/null
    create_test_session "arch-two" >/dev/null
    put_built_cs_on_path
    local out; out=$(bash_candidates_words "$BASH_COMP" cs -archive arch-one "")
    assert_candidate "$out" "arch-two" "cs -archive <name> <TAB> must offer a second session" || return 1
}

test_zsh_msg_completes_target_session() {
    command -v zsh >/dev/null 2>&1 || { echo "    (zsh not installed, skipping)"; return 0; }
    create_test_session "ztarget" >/dev/null
    put_built_cs_on_path
    local out; out=$(zsh_candidates_words cs -msg "")
    assert_candidate "$out" "ztarget" "zsh cs -msg <TAB> must offer a target session" || return 1
}

test_zsh_rm_completes_beyond_first_name() {
    command -v zsh >/dev/null 2>&1 || { echo "    (zsh not installed, skipping)"; return 0; }
    create_test_session "zkeep-one" >/dev/null
    create_test_session "zkeep-two" >/dev/null
    put_built_cs_on_path
    local out; out=$(zsh_candidates_words cs -rm zkeep-one "")
    assert_candidate "$out" "zkeep-two" "zsh cs -rm <name> <TAB> must offer a second session" || return 1
}

echo ""
echo "cs completion drift tests"
echo "========================="
echo ""

run_test test_complete_sessions_includes_symlinked_session
run_test test_complete_sessions_excludes_directories_without_a_session_marker
run_test test_complete_sessions_includes_a_legacy_session
run_test test_bash_completion_offers_a_symlinked_session
run_test test_bash_completion_before_the_fix_missed_symlinked_sessions
run_test test_zsh_completion_offers_a_symlinked_session
run_test test_bash_completion_offers_sessions_and_flags_on_an_empty_word
run_test test_zsh_completion_offers_sessions_and_flags_on_an_empty_word
run_test test_bash_completion_does_not_split_a_session_name_with_spaces
run_test test_bash_completion_does_not_glob_a_session_name_with_a_star
run_test test_bash_completion_does_not_enumerate_when_completing_a_flag
run_test test_zsh_completion_does_not_enumerate_when_completing_a_flag
run_test test_completions_delegate_session_enumeration_to_cs
run_test test_dispatch_extraction_is_sane
run_test test_hidden_commands_are_exempt_from_completion_coverage
run_test test_zsh_completion_covers_all_commands
run_test test_bash_completion_covers_all_commands
run_test test_secrets_extraction_is_sane
# Extract the queue subcommand tokens from run_queue's dispatch case in the
# built bin/cs, so completions can be checked against the real verb set.
queue_subcommands() {
    awk '/^run_queue\(\)/,/^\}/' "$CS_FILE" \
        | grep -oE '^ +[a-z|-]+\)' \
        | tr -d ' )' \
        | tr '|' '\n' \
        | sort -u
}

test_queue_extraction_is_sane() {
    local cmds
    cmds=$(queue_subcommands)
    assert_output_contains "$cmds" "add" "extraction should find add" || return 1
    assert_output_contains "$cmds" "log" "extraction should find log" || return 1
}

test_completions_cover_all_queue_subcommands() {
    # queue grew start/defer/log by hand-edit; this is the drift net the
    # top-level and secrets lists already have.
    local cmds c
    cmds=$(queue_subcommands)
    for c in $cmds; do
        grep -qE "(^|[^a-z-])${c}([^a-z-]|$)" "$ZSH_COMP" || {
            echo "  FAIL: completions/_cs missing queue subcommand: $c"; return 1; }
        grep -qE "(^|[^a-z-])${c}([^a-z-]|$)" "$BASH_COMP" || {
            echo "  FAIL: completions/cs.bash missing queue subcommand: $c"; return 1; }
    done
}

run_test test_zsh_completion_covers_all_secrets_subcommands
run_test test_bash_completion_covers_all_secrets_subcommands
run_test test_queue_extraction_is_sane
run_test test_completions_cover_all_queue_subcommands
run_test test_bash_msg_completes_target_session
run_test test_bash_spawn_completes_session_name
run_test test_bash_rm_completes_beyond_first_name
run_test test_bash_archive_completes_beyond_first_name
run_test test_zsh_msg_completes_target_session
run_test test_zsh_rm_completes_beyond_first_name

# Extract the SESSION subcommand arms — the second dispatch site, `cs <name>
# -verb`, which is a different vocabulary from the top-level one above. The arms
# sit at 12-space indent inside run_session's while/case; the awk range ends on
# the 8-space `esac`, so the nested `esac` inside the -msg arm does not close it
# early.
#
# The character class KEEPS `|` so an aliased arm like `-foo|-f)` matches and the
# `tr` below splits it into two names. Dropping `|` from the class does not merely
# lose the alias — the whole line stops matching, the arm vanishes from the set,
# and this drift net goes silently green on a verb nobody completed.
session_subcommands() {
    awk '/^    while \[ \$# -gt 0 \]; do/,/^        esac/' "$MAIN_LIB" \
        | grep -v '# hidden' \
        | grep -oE '^ {12}--?[a-zA-Z][a-zA-Z|-]*\)' \
        | tr -d ' )' \
        | tr '|' '\n' \
        | grep -E '^-' \
        | sort -u
}

test_session_extraction_is_sane() {
    local cmds
    cmds=$(session_subcommands)
    assert_output_contains "$cmds" "-secrets" "extraction should find -secrets" || return 1
    assert_output_contains "$cmds" "--merge" "extraction should find --merge" || return 1
    local n
    n=$(printf '%s\n' "$cmds" | grep -c . | tr -d '[:space:]')
    [ "${n:-0}" -ge 8 ] \
        || { echo "  FAIL: only $n session arms extracted; the range or regex is broken"; return 1; }
}

# The word list each completion offers AFTER a session name — the surface a
# session verb actually has to reach. Scoped to that list rather than to the
# whole file on purpose: every session verb also names a global flag, so a
# file-wide grep goes green on a verb that no session context ever offers, which
# is exactly how -narrative reached the dispatch uncompleted.
bash_session_opts() {
    grep -oE 'local session_opts="[^"]*"' "$BASH_COMP" | sed 's/.*="//; s/"$//' | tr ' ' '\n' | grep -E '^-' | sort -u
}

zsh_session_opts() {
    awk '/^        session_opts=\(/,/^        \)/' "$ZSH_COMP" \
        | grep -oE "'--?[a-zA-Z][a-zA-Z-]*:" | tr -d "':" | sort -u
}

test_session_opts_extraction_is_sane() {
    local b z
    b=$(bash_session_opts); z=$(zsh_session_opts)
    assert_output_contains "$b" "-secrets" "bash session_opts extraction should find -secrets" || return 1
    assert_output_contains "$z" "-secrets" "zsh session_opts extraction should find -secrets" || return 1
    local nb nz
    nb=$(printf '%s\n' "$b" | grep -c . | tr -d '[:space:]')
    nz=$(printf '%s\n' "$z" | grep -c . | tr -d '[:space:]')
    [ "${nb:-0}" -ge 8 ] || { echo "  FAIL: only $nb bash session opts extracted; the regex is broken"; return 1; }
    [ "${nz:-0}" -ge 8 ] || { echo "  FAIL: only $nz zsh session opts extracted; the range or regex is broken"; return 1; }
}

# Derived, not a hand-written list: a verb added to the dispatch and forgotten in
# a completion fails here without anyone remembering to update a pin. This is the
# surface that has drifted before.
test_every_session_subcommand_is_completed() {
    local verb missing_bash="" missing_zsh="" bash_opts zsh_opts
    bash_opts=$(bash_session_opts)
    zsh_opts=$(zsh_session_opts)
    while IFS= read -r verb; do
        [ -n "$verb" ] || continue
        grep -qxF -- "$verb" <<< "$bash_opts" || missing_bash="$missing_bash $verb"
        grep -qxF -- "$verb" <<< "$zsh_opts"  || missing_zsh="$missing_zsh $verb"
    done <<< "$(session_subcommands)"
    # Both reported before returning: an early return on the bash omission hides
    # the zsh one, and a verb forgotten in one file is almost always forgotten
    # in both — so the fixer would learn about the second only on a re-run.
    [ -z "$missing_bash" ] || echo "  FAIL: completions/cs.bash session_opts is missing:$missing_bash"
    [ -z "$missing_zsh" ]  || echo "  FAIL: completions/_cs session_opts is missing:$missing_zsh"
    [ -z "$missing_bash" ] && [ -z "$missing_zsh" ]
}

# The catch-all arm tells the user what they could have typed, so it is a third
# copy of the same vocabulary and drifts the same way.
test_unknown_session_command_error_lists_every_verb() {
    local err verb missing=""
    err=$(grep -F 'Unknown session command' "$MAIN_LIB" | head -1)
    [ -n "$err" ] || { echo "  FAIL: could not find the unknown-session-command error"; return 1; }
    while IFS= read -r verb; do
        [ -n "$verb" ] || continue
        case "$err" in *"$verb"*) ;; *) missing="$missing $verb" ;; esac
    done <<< "$(session_subcommands)"
    [ -z "$missing" ] \
        || { echo "  FAIL: the unknown-session-command error omits:$missing"; return 1; }
}

# -narrative takes exactly one subcommand, and a verb with no context arm in
# the word-scanning loop falls through to the generic flag case: the completion
# then re-offers the session-option list — including -narrative itself — where
# its subcommand belongs. Every peer verb (-queue, -secrets, -tag) sets a flag.
test_bash_completion_offers_rotate_after_narrative() {
    put_built_cs_on_path
    local out
    out=$(bash_candidates_words "$BASH_COMP" cs some-session -narrative "")
    assert_candidate "$out" "rotate" "bash must offer rotate after a session's -narrative" || return 1
    assert_not_candidate "$out" "-narrative" "the flag list must not be re-offered in its subcommand's place" || return 1
}

test_zsh_completion_offers_rotate_after_narrative() {
    command -v zsh >/dev/null 2>&1 || { echo "    (zsh not installed, skipping)"; return 0; }
    put_built_cs_on_path
    local out
    out=$(zsh_candidates_words cs some-session -narrative "")
    assert_candidate "$out" "rotate" "zsh must offer rotate after a session's -narrative" || return 1
}

test_bash_completion_offers_rotate_after_the_global_narrative() {
    put_built_cs_on_path
    local out
    out=$(bash_candidates_words "$BASH_COMP" cs -narrative "")
    assert_candidate "$out" "rotate" "bash must offer rotate after the global -narrative" || return 1
}

test_zsh_completion_offers_rotate_after_the_global_narrative() {
    command -v zsh >/dev/null 2>&1 || { echo "    (zsh not installed, skipping)"; return 0; }
    put_built_cs_on_path
    local out
    out=$(zsh_candidates_words cs -narrative "")
    assert_candidate "$out" "rotate" "zsh must offer rotate after the global -narrative" || return 1
}

run_test test_session_extraction_is_sane
run_test test_session_opts_extraction_is_sane
run_test test_bash_completion_offers_rotate_after_narrative
run_test test_zsh_completion_offers_rotate_after_narrative
run_test test_bash_completion_offers_rotate_after_the_global_narrative
run_test test_zsh_completion_offers_rotate_after_the_global_narrative
run_test test_every_session_subcommand_is_completed
run_test test_unknown_session_command_error_lists_every_verb

# Every verb must answer --help, derived from the dispatch rather than a list
# here. `cs -msg --help` used to report "No such session: --help" because the
# flag reached the mail parser as a target, which sends an agent looking for a
# session instead of for documentation.
test_every_verb_answers_help() {
    local verb rc out broken=""
    while IFS= read -r verb; do
        [ -n "$verb" ] || continue
        rc=0
        out=$("$CS_FILE" "$verb" --help 2>&1) || rc=$?
        if [ "$rc" != "0" ] || [ -z "$out" ]; then
            broken="$broken $verb(exit=$rc)"
            continue
        fi
        # The answer must be about that verb, not the whole manual and not an
        # error that merely happens to exit 0.
        case "$out" in
            *"$verb"*) ;;
            *) broken="$broken $verb(off-topic)" ;;
        esac
        case "$out" in
            Error:*) broken="$broken $verb(error-framed)" ;;
        esac
    done <<< "$(dispatch_commands; session_subcommands)"
    [ -z "$broken" ] \
        || { echo "  FAIL: these verbs do not answer --help cleanly:$broken"; return 1; }
}

run_test test_every_verb_answers_help

# -secrets is a delegation, not a verb cs answers itself: bin/cs-secrets holds
# the reference, and the interception runs ahead of the arm that forwards to it.
# test_every_verb_answers_help cannot catch this — it asks only for exit 0,
# non-empty output naming the verb, which the interception satisfies for every
# verb by construction. `migrate-backend` appears in the secrets reference and
# nowhere in cs's own help, so it distinguishes the two answers.
test_secrets_help_reaches_the_secrets_reference() {
    local flag out
    for flag in --help -h; do
        out=$("$CS_FILE" -secrets "$flag" 2>&1) || return 1
        assert_output_contains "$out" "migrate-backend" \
            "cs -secrets $flag must reach the cs-secrets reference" || return 1
    done
}

run_test test_secrets_help_reaches_the_secrets_reference

report_results
