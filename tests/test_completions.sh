#!/usr/bin/env bash
# ABOUTME: Guards against drift between bin/cs's command dispatch and the shell completions
# ABOUTME: Every top-level -command in bin/cs must appear in completions/_cs and completions/cs.bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_FILE="$SCRIPT_DIR/../bin/cs"
SECRETS_FILE="$SCRIPT_DIR/../bin/cs-secrets"
ZSH_COMP="$SCRIPT_DIR/../completions/_cs"
BASH_COMP="$SCRIPT_DIR/../completions/cs.bash"

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

# Drive bash's completion the way bash does: seed COMP_WORDS/COMP_CWORD, call the
# function, read back COMPREPLY. The completion script under test is passed in so
# a pre-fix copy can be checked against the same assertions.
bash_candidates_for() {
    local script="$1" word="$2"
    bash --norc --noprofile -c '
        PATH="$1:$PATH"
        source "$2"
        COMP_WORDS=(cs "$3")
        COMP_CWORD=1
        _cs_completions
        printf "%s\n" "${COMPREPLY[@]}"
    ' _ "$TEST_TMPDIR/bin" "$script" "$word" 2>/dev/null
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

# Drive zsh's completion by stubbing _describe, which is where _cs hands off its
# candidates. _describe takes the NAME of an array, so the stub expands it with
# the (P) parameter-name flag. Filtering against the typed word is zsh's job, not
# _cs's, so what this captures is the full candidate set.
zsh_candidates_for_first_word() {
    local word="$1"
    zsh -f -c '
        PATH="$1:$PATH"
        _describe() { local arr=${@[-1]}; print -rl -- ${(P)arr} }
        words=(cs "$2")
        CURRENT=2
        source "$3"
    ' _ "$TEST_TMPDIR/bin" "$word" "$ZSH_COMP" 2>/dev/null | sed 's/:.*//'
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
run_test test_zsh_completion_covers_all_secrets_subcommands
run_test test_bash_completion_covers_all_secrets_subcommands

report_results
