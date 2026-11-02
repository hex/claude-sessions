#!/usr/bin/env bash
# ABOUTME: Tests for cs -spawn: validation, seed staging, tmux window wiring,
# ABOUTME: launch-path seed consumption, and the spawned-by drain notify.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
# Hooks resolve `cs` via PATH (the drain notify calls it); point them at the
# repo build for the whole suite.
export PATH="$SCRIPT_DIR/../bin:$PATH"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    export CLAUDE_CODE_BIN="echo"
    # The attach hint keys on $TMUX; unset it so the baseline is deterministic
    # regardless of whether the suite itself runs inside tmux.
    unset TMUX 2>/dev/null || true
    # Recording tmux fake: logs argv, one call per line; behavior driven by
    # state files in $TEST_TMPDIR/tmux-state (see comments inside).
    export CS_TMUX_BIN="$TEST_TMPDIR/fake-tmux"
    export FAKE_TMUX_DIR="$TEST_TMPDIR/tmux-state"
    mkdir -p "$FAKE_TMUX_DIR"
    cat > "$CS_TMUX_BIN" << 'FAKE'
#!/usr/bin/env bash
# Fake tmux: append argv to log; simulate state via files in $FAKE_TMUX_DIR.
#   has-session  -> exit 0 iff $FAKE_TMUX_DIR/session-exists exists
#   new-session  -> creates session-exists (fails if $FAKE_TMUX_DIR/race);
#                   with -P prints @0
#   set-option   -> records @cs_managed into $FAKE_TMUX_DIR/managed
#   show-option  -> prints contents of $FAKE_TMUX_DIR/managed (if any)
#   list-windows -> prints lines of $FAKE_TMUX_DIR/windows (if any)
#   new-window   -> with -P prints @7
printf '%s\n' "$*" >> "$FAKE_TMUX_DIR/log"
case "$1" in
    has-session)  [ -f "$FAKE_TMUX_DIR/session-exists" ]; exit $? ;;
    new-session)  # real tmux rejects a duplicate -s name; model that too
                  if [ -f "$FAKE_TMUX_DIR/race" ] || [ -f "$FAKE_TMUX_DIR/session-exists" ]; then exit 1; fi
                  touch "$FAKE_TMUX_DIR/session-exists"
                  case "$*" in *" -P "*) echo '@0';; esac ;;
    # tmux 3.6a rejects '='-anchored targets on the options commands (verified
    # live 2026-07-18: "no such session: =cs"); model that so the suite pins
    # the plain-target requirement for these two.
    set-option)   case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  printf '1\n' > "$FAKE_TMUX_DIR/managed" ;;
    show-option)  case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  [ -f "$FAKE_TMUX_DIR/managed" ] && cat "$FAKE_TMUX_DIR/managed" ;;
    list-windows) [ -f "$FAKE_TMUX_DIR/windows" ] && cat "$FAKE_TMUX_DIR/windows" ;;
    new-window)   case "$*" in *" -P "*) echo '@7';; esac ;;
esac
exit 0
FAKE
    chmod +x "$CS_TMUX_BIN"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN FAKE_TMUX_DIR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

SEED() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.seed"; }
BRIEF() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"; }

# A seed as cs -spawn writes it: line 1 is the token the spawn's own tmux
# window carries in CS_SPAWN_TOKEN, line 2 the spawner, then one task per
# line. An open that carries the token is the spawn's own window and consumes
# the seed unasked; any other open is shown the seed and asked.
OWN_TOKEN=0123456789abcdef0123456789abcdef
_stage_seed() {  # spawner, tasks...
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    local spawner="$1" t
    shift
    { printf '%s\n%s\n' "$OWN_TOKEN" "$spawner"
      for t in "$@"; do printf '%s\n' "$t"; done
    } > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
}

# A seed that carries a brief: the task lines end at the marker line, and
# every line after it is the brief, verbatim.
BRIEF_MARK='--- cs-spawn-brief ---'
_stage_seed_with_brief() {  # brief text, spawner, tasks...
    local brief="$1"
    shift
    _stage_seed "$@"
    printf '%s\n%s' "$BRIEF_MARK" "$brief" >> "$CS_SESSIONS_ROOT/.spawn/worker.seed"
}

test_spawn_rejects_bad_names_and_missing_tmux() {
    ! "$CS_BIN" -spawn "bad name" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn "../x" >/dev/null 2>&1 || return 1
    ! CS_TMUX_BIN=/nonexistent/tmux "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_rejects_live_target() {
    create_test_session worker >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs"
    printf '%s\n' "$$" > "$CS_SESSIONS_ROOT/worker/.cs/session.lock"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_writes_seed_and_opens_window() {
    local out
    out=$(CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker \
        --task "first job" --task "second job" 2>&1) || return 1
    assert_file_exists "$(SEED)" "seed written" || return 1
    local tok; tok="$(sed -n 1p "$(SEED)")"
    printf '%s' "$tok" | grep -Eq '^[0-9a-f]{32}$' || { echo "  line 1 is not a 32-hex token: '$tok'"; return 1; }
    assert_eq "boss" "$(sed -n 2p "$(SEED)")" "line 2 is spawner" || return 1
    assert_eq "first job" "$(sed -n 3p "$(SEED)")" "task order kept" || return 1
    assert_eq "second job" "$(sed -n 4p "$(SEED)")" "second task" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "'CS_SPAWN_TOKEN=$tok'" "the window command carries the seed's token" || return 1
    assert_output_contains "$out" "@0" "window id echoed" || return 1
    assert_output_contains "$out" "tmux attach -t cs" "attach hint" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session -d -s cs" "created cs session" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "set-option -t cs @cs_managed 1" "ownership stamped" || return 1
}

test_spawn_tmux_targets_are_exact_match_anchored() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    # Resolver commands must anchor with =; the options commands must NOT
    # (tmux 3.6a rejects '=' targets on set-option/show-option), and they are
    # unambiguous anyway because they only run once exact 'cs' exists.
    ! grep -E -- '^(has-session|list-windows|new-window) .*-t cs( |$)' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  unanchored resolver target found"; return 1; }
    grep -F -- '-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  no anchored resolver target"; return 1; }
    ! grep -E -- '^(set-option|show-option) .*-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  anchored options-command target found"; return 1; }
}

test_spawn_empty_spawner_writes_blank_first_line() {
    env -u CLAUDE_SESSION_NAME "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 || return 1
    assert_eq "" "$(sed -n 2p "$(SEED)")" "blank spawner line" || return 1
    assert_eq "solo" "$(sed -n 3p "$(SEED)")" "task on line 3" || return 1
}

# The spawner line becomes the worker's report-back address (cs -msg <spawner>
# -k result) and its kick prompt; it comes from the environment, so only a
# session name gets in.
test_spawn_rejects_an_invalid_spawner_name() {
    local out
    ! out=$(CLAUDE_SESSION_NAME="bad name; rm" "$CS_BIN" -spawn worker --task "solo" 2>&1) \
        || { echo "  spawn accepted an invalid spawner name"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed written for an invalid spawner"; return 1; }
    assert_output_contains "$out" "CLAUDE_SESSION_NAME" "the error names the source" || return 1
    CLAUDE_SESSION_NAME="base@task" "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 \
        || { echo "  a worktree spawner name refused"; return 1; }
}

test_spawn_without_task_writes_no_seed() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written without --task"; return 1; }
}

# A brief is the multi-line counterpart of --task: a file the spawned session
# reads before it begins. It rides inside the seed, verbatim after the marker
# line, so the pair is one file; a brief alone is reason enough for a seed,
# since the seed carries the spawner.
test_spawn_stages_the_brief_inside_the_seed() {
    printf '# Goal\n\nAdd the refresh-token path.\n\n## Done when\n- suite green' > "$TEST_TMPDIR/brief.md"
    CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 || return 1
    assert_file_exists "$(SEED)" "a brief alone writes a seed" || return 1
    assert_eq "boss" "$(sed -n 2p "$(SEED)")" "seed carries the spawner" || return 1
    assert_eq "$BRIEF_MARK" "$(sed -n 3p "$(SEED)")" "the marker follows the spawner when there are no tasks" || return 1
    tail -n +4 "$(SEED)" > "$TEST_TMPDIR/staged-brief"
    cmp -s "$TEST_TMPDIR/brief.md" "$TEST_TMPDIR/staged-brief" || { echo "  the brief in the seed differs from the source"; return 1; }
    [ ! -e "$(BRIEF)" ] || { echo "  a brief file was staged beside the seed"; return 1; }
    assert_eq "worker.seed" "$(ls -A "$CS_SESSIONS_ROOT/.spawn")" "nothing but the seed is left in .spawn" || return 1
}

test_spawn_brief_and_tasks_stage_together() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" --task "first job" >/dev/null 2>&1 || return 1
    assert_eq "first job" "$(sed -n 3p "$(SEED)")" "task staged before the brief" || return 1
    assert_eq "$BRIEF_MARK" "$(sed -n 4p "$(SEED)")" "the marker follows the tasks" || return 1
    assert_eq "brief body" "$(sed -n 5p "$(SEED)")" "the brief follows the marker" || return 1
}

# The marker line ends a seed's tasks, so a task spelled the same would cut
# the task list short and turn the rest into a brief.
test_spawn_refuses_a_task_equal_to_the_brief_marker() {
    local rc=0 err
    err=$("$CS_BIN" -spawn worker --task "$BRIEF_MARK" 2>&1 >/dev/null) && rc=1
    [ "$rc" = 0 ] || { echo "  a task equal to the marker was accepted"; return 1; }
    assert_output_contains "$err" "cannot be a task" "the refusal says why" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/.spawn" ] || [ -z "$(ls -A "$CS_SESSIONS_ROOT/.spawn")" ] \
        || { echo "  something was staged for a refused task"; return 1; }
}

# Two spawns of one name at once: exactly one publishes, and what it publishes
# is all its own. A --brief spawn racing a task-only one must never leave a
# seed carrying the other's brief, and the loser leaves no file behind.
test_spawn_concurrent_same_name_publishes_one_whole_seed() {
    printf 'brief from A\n' > "$TEST_TMPDIR/a.md"
    local i=0 pa pb rca rcb
    while [ "$i" -lt 10 ]; do
        i=$((i + 1))
        rm -rf "$CS_SESSIONS_ROOT/.spawn" "$FAKE_TMUX_DIR"
        mkdir -p "$FAKE_TMUX_DIR"
        "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/a.md" >/dev/null 2>&1 & pa=$!
        "$CS_BIN" -spawn worker --task "task from B" >/dev/null 2>&1 & pb=$!
        rca=0; wait "$pa" || rca=$?
        rcb=0; wait "$pb" || rcb=$?
        if [ "$rca" = 0 ] && [ "$rcb" = 0 ]; then echo "  round $i: both spawns reported success"; return 1; fi
        if [ "$rca" != 0 ] && [ "$rcb" != 0 ]; then echo "  round $i: neither spawn succeeded ($rca, $rcb)"; return 1; fi
        assert_eq "worker.seed" "$(ls -A "$CS_SESSIONS_ROOT/.spawn")" "round $i: one seed and nothing else" || return 1
        if [ "$rca" = 0 ]; then
            assert_eq "$BRIEF_MARK" "$(sed -n 3p "$(SEED)")" "round $i: A's seed carries A's brief" || return 1
            assert_eq "brief from A" "$(sed -n 4p "$(SEED)")" "round $i: A's brief" || return 1
            ! grep -q "task from B" "$(SEED)" || { echo "  round $i: A's seed carries B's task"; return 1; }
        else
            assert_eq "task from B" "$(sed -n 3p "$(SEED)")" "round $i: B's seed carries B's task" || return 1
            ! grep -qxF -- "$BRIEF_MARK" "$(SEED)" || { echo "  round $i: B's seed carries a brief"; return 1; }
        fi
    done
}

test_spawn_rejects_unreadable_or_empty_brief_before_staging() {
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/absent.md" >/dev/null 2>&1 || return 1
    : > "$TEST_TMPDIR/empty.md"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/empty.md" >/dev/null 2>&1 || return 1
    printf 'secret brief\n' > "$TEST_TMPDIR/locked.md"
    chmod 000 "$TEST_TMPDIR/locked.md"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/locked.md" >/dev/null 2>&1 && rc=1
    chmod 600 "$TEST_TMPDIR/locked.md"
    [ "$rc" = 0 ] || { echo "  an unreadable brief was accepted"; return 1; }
    ! "$CS_BIN" -spawn worker --brief >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on a rejected brief"; return 1; }
    [ ! -f "$(BRIEF)" ] || { echo "  brief staged on a rejected brief"; return 1; }
    [ ! -f "$FAKE_TMUX_DIR/log" ] || { echo "  a window was opened on a rejected brief"; return 1; }
}

# The seed is the launch's signal that staging is complete. A brief that
# could not be copied must stop the spawn before the seed exists, or the
# window opens and the session launches without the brief it was promised.
test_spawn_failed_brief_copy_publishes_no_seed() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    chmod 500 "$CS_SESSIONS_ROOT/.spawn"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 && rc=1
    chmod 700 "$CS_SESSIONS_ROOT/.spawn"
    [ "$rc" = 0 ] || { echo "  a failed brief copy still reported success"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed published after the brief copy failed"; return 1; }
    [ -z "$(ls -A "$CS_SESSIONS_ROOT/.spawn")" ] || { echo "  staging left files behind: $(ls -A "$CS_SESSIONS_ROOT/.spawn")"; return 1; }
    # The precheck's has-session is logged too; only the window commands count.
    ! grep -E -q '^(new-session|new-window) ' "$FAKE_TMUX_DIR/log" 2>/dev/null \
        || { echo "  a window was opened after the brief copy failed"; return 1; }
}

# A spawn killed before it published leaves only its own dot-named staging
# file. No launch reads it, and the next spawn of the name stages and
# publishes its own seed beside it, untouched by the leftover's brief.
test_spawn_a_killed_spawns_staging_file_is_never_published() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '%s\nboss\n%s\nbrief of the killed spawn\n' "$OWN_TOKEN" "$BRIEF_MARK" > "$CS_SESSIONS_ROOT/.spawn/.worker.seed.Ab12Cd"
    "$CS_BIN" -spawn worker --task "next job" >/dev/null 2>&1 || { echo "  the leftover blocked the next spawn"; return 1; }
    assert_eq "next job" "$(sed -n 3p "$(SEED)")" "the next spawn published its own task" || return 1
    ! grep -q "killed spawn" "$(SEED)" || { echo "  the next seed carries the killed spawn's brief"; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/.worker.seed.Ab12Cd" "killed spawn" "the leftover is not rewritten" || return 1
}

# The seed refusal already covers a pending brief: a brief never exists
# without its seed. This pins that a second spawn cannot swap the brief out
# from under the pending one.
test_spawn_refuses_to_replace_a_pending_brief() {
    printf 'first\n' > "$TEST_TMPDIR/one.md"
    printf 'second\n' > "$TEST_TMPDIR/two.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/one.md" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/two.md" >/dev/null 2>&1 || return 1
    assert_eq "first" "$(tail -n +4 "$(SEED)")" "pending brief untouched" || return 1
}

test_spawn_attach_hint_uses_switch_client_inside_tmux() {
    # tmux attach refuses to nest; from inside tmux the user needs switch-client.
    local out
    out=$(TMUX="/tmp/tmux-1000/default,1234,0" "$CS_BIN" -spawn worker 2>&1) || return 1
    assert_output_contains "$out" "tmux switch-client -t cs" "switch-client hint inside tmux" || return 1
    assert_output_not_contains "$out" "tmux attach -t cs" "no attach hint inside tmux" || return 1
}

test_spawn_refuses_existing_seed() {
    "$CS_BIN" -spawn worker --task "a" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --task "b" >/dev/null 2>&1 || return 1
    assert_eq "a" "$(sed -n 3p "$(SEED)")" "original seed untouched" || return 1
}

test_spawn_rejects_multiline_and_empty_task() {
    ! "$CS_BIN" -spawn worker --task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn worker --task "   " >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on rejected task"; return 1; }
}

test_spawn_refuses_unmanaged_cs_session() {
    touch "$FAKE_TMUX_DIR/session-exists"     # a session named cs exists...
    rm -f "$FAKE_TMUX_DIR/managed"            # ...but carries no @cs_managed
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_refuses_duplicate_window() {
    touch "$FAKE_TMUX_DIR/session-exists"
    printf '1\n' > "$FAKE_TMUX_DIR/managed"
    printf 'worker\n' > "$FAKE_TMUX_DIR/windows"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_window_command_is_quoted_absolute() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    grep -F "'/" "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  window cmd not quoted-absolute"; return 1; }
    assert_file_contains "$FAKE_TMUX_DIR/log" "'worker'" "name quoted" || return 1
}

# Work handed to a session that already exists goes through that session's
# user: another session's tasks or brief would otherwise be queued, armed and
# kicked by the spawn's own window with nobody asked.
test_spawn_refuses_another_sessions_tasks_for_an_existing_session() {
    create_test_session worker >/dev/null
    local out rc=0
    out=$(CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker --task "first job" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the spawn exits 1" || return 1
    assert_eq "Error: session boss cannot hand work to the existing session worker; send it as task mail for worker's user to accept: cs -msg worker --kind task \"<task>\"" \
        "$out" "the refusal names the mail route" || return 1
    assert_not_exists "$(SEED)" "no seed staged" || return 1
    assert_not_exists "$FAKE_TMUX_DIR/log" "no window opened" || return 1
}

test_spawn_from_a_terminal_still_hands_an_existing_session_its_tasks() {
    create_test_session worker >/dev/null
    env -u CLAUDE_SESSION_NAME "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 || { echo "  spawn failed"; return 1; }
    assert_eq "solo" "$(sed -n 3p "$(SEED)")" "the task is staged" || return 1
}

# A feature brief with every section the feature skill's shape names.
_feature_brief() {  # path
    printf '# feature\n\n## Goal\nShip it.\n\n## Done when\n- green\n\n## Constraints\n- none\n\n## Context\n- base at abc123\n\n## Review\n- independent review before the result\n\n## Report back\ncs -msg base -k result "done"\n' > "$1"
}

# A feature's brief is the feature skill's shape, and the spawner holds the
# writer to it: a feature-named spawn whose brief lacks a section is refused
# naming the first missing one, and nothing is staged. A plain session's brief
# has no shape (test_spawn_stages_the_brief_inside_the_seed stages one with a
# bare "# Goal").
test_spawn_refuses_a_feature_brief_missing_a_section() {
    local brief="$TEST_TMPDIR/brief.md" err rc=0
    _feature_brief "$brief"
    grep -v '^## Context$' "$brief" > "$brief.cut" && mv "$brief.cut" "$brief"
    err=$(CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" 2>&1 >/dev/null) && rc=1
    [ "$rc" = 0 ] || { echo "  a feature brief without ## Context was accepted"; return 1; }
    assert_eq "Error: cs -spawn --brief: $brief has no '## Context' section; a feature brief carries ## Goal, ## Done when, ## Constraints, ## Context, ## Review and ## Report back, each on its own line" \
        "$err" "the refusal names the missing section and the shape" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/.spawn" ] || [ -z "$(ls -A "$CS_SESSIONS_ROOT/.spawn")" ] \
        || { echo "  something was staged for a refused brief"; return 1; }
    # A heading with trailing words is not the section.
    _feature_brief "$brief"
    sed 's/^## Review$/## Review notes/' "$brief" > "$brief.cut" && mv "$brief.cut" "$brief"
    err=$(CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" 2>&1 >/dev/null) && rc=1
    [ "$rc" = 0 ] || { echo "  '## Review notes' passed for '## Review'"; return 1; }
    assert_output_contains "$err" "has no '## Review' section" "a heading with extra words is not the section" || return 1
}

# The sections are read as Markdown reads them: CRLF, a byte-order mark and
# trailing blanks do not hide a heading, and a heading inside a code fence is
# not one.
test_spawn_reads_feature_brief_sections_as_markdown() {
    local brief="$TEST_TMPDIR/brief.md" err rc=0
    _feature_brief "$brief"
    { printf '\xef\xbb\xbf'; sed '1,2d; s/$/\r/; s/^## Review\r$/## Review  \r/' "$brief"; } > "$brief.alt" && mv "$brief.alt" "$brief"
    CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" >/dev/null 2>&1 \
        || { echo "  a CRLF brief with a BOM and a trailing blank was refused"; return 1; }
    rm -rf "$CS_SESSIONS_ROOT/.spawn" "$FAKE_TMUX_DIR"; mkdir -p "$FAKE_TMUX_DIR"
    _feature_brief "$brief"
    { printf '# feature\n\n```\n'; sed 1d "$brief"; printf '```\n'; } > "$brief.alt" && mv "$brief.alt" "$brief"
    err=$(CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" 2>&1 >/dev/null) && rc=1
    [ "$rc" = 0 ] || { echo "  six headings inside a code fence passed as sections"; return 1; }
    assert_output_contains "$err" "has no '## Goal' section" "a fenced heading is not a section" || return 1
}

test_spawn_accepts_a_complete_feature_brief() {
    local brief="$TEST_TMPDIR/brief.md"
    _feature_brief "$brief"
    CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" >/dev/null 2>&1 \
        || { echo "  a complete feature brief was refused"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/base@feature.seed" "the brief is staged" || return 1
}

test_spawn_from_the_base_still_briefs_its_existing_feature() {
    create_test_session base@feature >/dev/null
    local brief="$TEST_TMPDIR/brief.md"
    _feature_brief "$brief"
    CLAUDE_SESSION_NAME="base" "$CS_BIN" -spawn base@feature --brief "$brief" >/dev/null 2>&1 \
        || { echo "  spawn failed"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/base@feature.seed" "the brief is staged" || return 1
}

test_spawn_accepts_worktree_name() {
    "$CS_BIN" -spawn base@feature >/dev/null 2>&1 || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "base@feature" "worktree window opened" || return 1
}

test_spawn_new_session_race_falls_through_to_new_window() {
    touch "$FAKE_TMUX_DIR/race"   # new-session fails as if a concurrent spawner won
    local out
    out=$("$CS_BIN" -spawn worker 2>&1) || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session" "new-session attempted" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-window" "fell through to new-window" || return 1
    assert_output_contains "$out" "@7" "window id from the fallthrough" || return 1
}

WQ() { printf '%s' "$CS_SESSIONS_ROOT/worker/.cs/local"; }

# Count task files in the worker's queue directory.
WQ_COUNT() {
    local f n=0
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Content of the lexically first queued task (empty when none).
WQ_FIRST() {
    local f
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        cat "$f"
        return 0
    done
}

# Launch recipe (same as tests/test_uuid.sh): CLAUDE_CODE_BIN=echo makes cs's
# `exec $CLAUDE_CODE_BIN <args>` print claude's argv; <<< "" answers any read.
# The recipe opens as the spawn's own window (CS_SPAWN_TOKEN matches the
# seed), the unattended path; the consent tests below open without it.
_launch_worker() {
    CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker <<< "" 2>&1
}

# A foreign open on a terminal: the consent ask reads a keypress from a tty,
# never from redirected stdin, so the launch runs on a pty and the keys are
# typed once the ask appears. Keys take Python escapes (\r, \x1b). Output
# comes back with CRLF folded. BEFORE_KEYS, when set, is a shell command run
# while the ask waits, just before the keys are typed, with PTY_PID set to
# the pid of cs on the pty.
_launch_worker_on_tty() {  # keys, [VAR=value ...]
    local keys="$1"; shift
    env "$@" python3 - "$keys" "$CS_BIN" worker << 'PY'
import os, pty, select, sys, time
keys = sys.argv[1].encode("latin1").decode("unicode_escape").encode("latin1")
cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out = b""
sent = False
start = time.time()
while True:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out += data
    if not sent and (b"[Y/n]" in out or time.time() - start > 8):
        if os.environ.get("BEFORE_KEYS"):
            os.environ["PTY_PID"] = str(pid)
            os.system(os.environ["BEFORE_KEYS"])
        if keys:
            os.write(fd, keys)
        sent = True
    if time.time() - start > 20:
        os.kill(pid, 9)
        break
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out.replace(b"\r\n", b"\n"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
}

test_launch_consumes_seed_queues_arms_and_kicks() {
    _stage_seed boss "first job" "second job"
    local out; out=$(_launch_worker) || return 1
    grep -q "first job" "$(WQ)/queue"/* || { echo "  task 1 not queued"; return 1; }
    grep -q "second job" "$(WQ)/queue"/* || { echo "  task 2 not queued"; return 1; }
    assert_eq "first job" "$(WQ_FIRST)" "queue order kept" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "kick prompt in claude argv" || return 1
    assert_output_contains "$out" "2 task(s)" "kick counts tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
}

# A pane claude splits off for an agent-team teammate is started by the tmux
# server with the tmux session's environment, not the lead's, so the truecolor
# override cs exports for claude never reaches it and the teammate's status
# line renders in the 256-colour fallback. The launch publishes the value into
# the tmux session it runs in. The fake tmux is also first on PATH: the tab
# title code calls tmux by name, and with TMUX set a real tmux would rename the
# window this suite runs in.
_launch_worker_in_tmux() {  # [truecolor value]
    mkdir -p "$TEST_TMPDIR/bin" && ln -sf "$CS_TMUX_BIN" "$TEST_TMPDIR/bin/tmux"
    # The default case unsets the variable: a suite run from a shell that
    # carries one (every cs session does) would otherwise test that value.
    if [ $# -gt 0 ]; then
        PATH="$TEST_TMPDIR/bin:$PATH" TMUX="/tmp/fake,1,0" CLAUDE_CODE_TMUX_TRUECOLOR="$1" "$CS_BIN" worker <<< "" > /dev/null 2>&1
    else
        ( unset CLAUDE_CODE_TMUX_TRUECOLOR; PATH="$TEST_TMPDIR/bin:$PATH" TMUX="/tmp/fake,1,0" "$CS_BIN" worker <<< "" > /dev/null 2>&1 )
    fi
}

test_launch_publishes_truecolor_to_the_tmux_session() {
    _launch_worker_in_tmux || true
    assert_file_contains "$FAKE_TMUX_DIR/log" "^set-environment CLAUDE_CODE_TMUX_TRUECOLOR 1$" \
        "the launch sets the truecolor flag in the tmux session env" || return 1
}

# The user's own value wins, as it does for claude's environment.
test_launch_publishes_the_users_truecolor_value() {
    _launch_worker_in_tmux 0 || true
    assert_file_contains "$FAKE_TMUX_DIR/log" "^set-environment CLAUDE_CODE_TMUX_TRUECOLOR 0$" \
        "a preset value is published as given" || return 1
}

# A teammate's hooks walk in from the session directory and accept it only
# when the sessions root knows it; the root they read is CS_SESSIONS_ROOT or
# the default. The teammate inherits the tmux server's environment, so a
# launch under another root must publish it there or every teammate of that
# session declines.
test_launch_publishes_the_sessions_root_to_the_tmux_session() {
    _launch_worker_in_tmux || true
    assert_file_contains "$FAKE_TMUX_DIR/log" "^set-environment CS_SESSIONS_ROOT $CS_SESSIONS_ROOT$" \
        "the launch sets the sessions root in the tmux session env" || return 1
}

test_launch_outside_tmux_touches_no_tmux_environment() {
    _launch_worker > /dev/null 2>&1 || true
    if [ -f "$FAKE_TMUX_DIR/log" ] && grep -q "set-environment" "$FAKE_TMUX_DIR/log"; then
        echo "  FAIL: set-environment called with no tmux around"; return 1
    fi
}

test_launch_empty_spawner_gets_no_reply_wiring() {
    _stage_seed "" "only job"
    local out; out=$(_launch_worker) || return 1
    grep -q "only job" "$(WQ)/queue"/* || { echo "  task not queued"; return 1; }
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written for empty spawner"; return 1; }
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
    assert_output_not_contains "$out" "Spawned by" "no spawner attribution" || return 1
    assert_output_not_contains "$out" "-k result" "no reply instructions" || return 1
}

# A staged brief becomes the session's own file, .cs/brief.md, and the kick
# sends the session to it before anything else. With no tasks there is no
# queue to drain, so the report-back is by hand and the kick says how.
test_launch_delivers_the_seeds_brief_and_kicks_to_it() {
    _stage_seed_with_brief $'# Goal\n\n--- not the marker ---\nrefresh tokens\n\n' boss
    local out; out=$(_launch_worker) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "brief delivered into the session" || return 1
    printf '# Goal\n\n--- not the marker ---\nrefresh tokens\n\n' > "$TEST_TMPDIR/expected-brief.md"
    cmp -s "$TEST_TMPDIR/expected-brief.md" "$CS_SESSIONS_ROOT/worker/.cs/brief.md" \
        || { echo "  the delivered brief differs from the staged one"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "spawner named" || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_not_contains "$out" "armed with" "no queue promised without tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded for a brief-only spawn" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed with no tasks"; return 1; }
}

# A brief file beside the seed belongs to no spawn the seed knows of: a
# --brief spawn killed before it published, or a cs from before the brief
# moved into the seed. A task-only spawn's session must not receive it.
test_launch_ignores_a_brief_file_beside_the_seed() {
    _stage_seed boss "first job"
    printf 'a brief from another spawn\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker) || return 1
    [ ! -e "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  the session received a brief its spawn never staged"; return 1; }
    assert_output_not_contains "$out" "Your brief is" "no kick to a brief the spawn never staged" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "the seed's own task still runs" || return 1
}

test_launch_brief_with_tasks_kicks_to_both() {
    _stage_seed_with_brief $'brief body\n' boss "first job"
    local out; out=$(_launch_worker) || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick counts tasks" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
    assert_eq "first job" "$(WQ_FIRST)" "only the task line is queued" || return 1
    assert_eq "1" "$(WQ_COUNT)" "the brief adds no task" || return 1
}

# A brief the launch cannot move into the session must stop the launch with
# the seed and brief still staged, so the next open retries; consuming the
# seed would start the session without the brief, and leave the brief to
# A writable directory at the brief's destination is worse than a sealed one:
# mv would put the brief INSIDE it, the launch would count the delivery a
# success, and Claude would be told to read a directory.
test_launch_refuses_a_directory_at_the_briefs_destination() {
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    _stage_seed_with_brief $'brief body\n' boss "first job"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    [ "$rc" != 0 ] || { echo "  launch succeeded with a directory in the brief's place"; return 1; }
    [ -z "$(ls -A "$CS_SESSIONS_ROOT/worker/.cs/brief.md")" ] || { echo "  the brief was written inside the directory"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "brief body" "the kept seed still holds the brief" || return 1
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
    assert_output_contains "$out" "brief" "the failure names the brief" || return 1
}

# attach to some later, unrelated spawn of the same name.
test_launch_failed_brief_delivery_keeps_the_seed() {
    # First open creates the session; then the brief's destination is made
    # undeliverable (a sealed directory in its place) while the staging
    # directory stays writable, so only the delivery can fail.
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    chmod 500 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    _stage_seed_with_brief $'brief body\n' boss "first job"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    chmod 700 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    [ "$rc" != 0 ] || { echo "  launch succeeded without delivering the brief"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "brief body" "the kept seed still holds the brief" || return 1
    [ -z "$(ls -A "$CS_SESSIONS_ROOT/worker/.cs/brief.md")" ] || { echo "  a brief appeared in the session anyway"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick without the brief" || return 1
    assert_output_contains "$out" "brief" "the failure names the brief" || return 1
}

test_launch_stale_seed_sets_its_brief_aside_too() {
    _stage_seed_with_brief $'old brief\n' boss
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "old brief" "the stale seed keeps its brief" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  stale seed still staged"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  stale brief applied to the session"; return 1; }
    assert_output_not_contains "$out" "Your brief is" "no kick from a stale brief" || return 1
}

test_launch_without_seed_keeps_color_behavior() {
    local out; out=$(_launch_worker) || return 1
    assert_output_not_contains "$out" "armed with" "no kick without seed" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed without seed"; return 1; }
}

test_launch_sets_aside_stale_seed() {
    _stage_seed boss "old job"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  stale seed still active"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "stale set aside" || return 1
    assert_eq "0" "$(WQ_COUNT)" "stale seed queued no work" || return 1
    assert_output_not_contains "$out" "armed with" "no kick from stale seed" || return 1
}

test_launch_stale_warning_names_the_stale_file() {
    _stage_seed boss "old job"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "worker.seed.stale" "warning names the stale file" || return 1
}

test_launch_fresh_boundary_seed_is_consumed() {
    # A seed 30 minutes old is comfortably inside the 3600s TTL.
    _stage_seed boss "boundary job"
    touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '-30 minutes' +%Y%m%d%H%M)" \
        "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "fresh-side seed consumed" || return 1
}

test_launch_seed_bypasses_resume_ask() {
    # First launch creates the session; second would normally ask "Continue
    # previous conversation? [Y/n]". In the spawn's own window, no ask: stdin
    # is closed so a read would die, proving the prompt was skipped.
    _launch_worker >/dev/null || return 1
    _stage_seed boss "resume job"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "seed consumed on resume" || return 1
    assert_output_not_contains "$out" "Continue previous conversation" "resume ask bypassed" || return 1
}

# Consent (audit H2). A seed is a file in .spawn/; anything that can write
# there used to arm the next open of the name, by hand or by a script, with
# whatever it staged, and the kick told Claude to begin. Only the spawn's own
# tmux window, which carries the seed's token, consumes unasked. Every other
# open is shown the seed as data and asked.
test_launch_own_window_consumes_without_asking() {
    _stage_seed boss "own job"
    local out; out=$(CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "seed consumed" || return 1
    assert_output_not_contains "$out" "\\[Y/n\\]" "no consent ask in the spawn's own window" || return 1
}

test_launch_foreign_seed_unattended_stays_staged() {
    _stage_seed_with_brief $'brief body\n' boss "foreign job"
    local out; out=$("$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "brief body" "the staged seed keeps its brief" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  brief delivered without consent"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued without consent" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed without consent"; return 1; }
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written without consent"; return 1; }
    assert_output_not_contains "$out" "armed with" "no kick without consent" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick without consent" || return 1
    assert_output_contains "$out" "worker.seed" "the launch names the staged seed" || return 1
}

test_launch_wrong_token_is_a_foreign_open() {
    _stage_seed boss "foreign job"
    local out; out=$(CS_SPAWN_TOKEN="ffffffffffffffffffffffffffffffff" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a token mismatch" || return 1
}

test_launch_seed_without_a_token_line_is_foreign() {
    # A seed written by an older cs, or by hand: line 1 is the spawner. An
    # empty CS_SPAWN_TOKEN never matches an empty token line.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '\nold job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(CS_SPAWN_TOKEN="" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued" || return 1
}

# Codex round 1: `<<< ""` hands the ask a newline, which read -rsn1 returns
# as the empty answer, and the default arm consumed a foreign seed with no
# human at all. Redirected stdin of any content leaves the seed staged.
test_launch_foreign_seed_redirected_stdin_stays_staged() {
    _stage_seed boss "foreign job"
    local out
    out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged on a piped newline" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a piped newline" || return 1
    out=$("$CS_BIN" worker <<< "y" 2>&1) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed left staged on a piped y" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued on a piped y" || return 1
    assert_output_not_contains "$out" "Take the seed" "no ask without a terminal" || return 1
    assert_output_contains "$out" "worker.seed" "the launch names the staged seed" || return 1
}

test_launch_foreign_seed_consent_shows_it_and_enter_consumes() {
    _stage_seed_with_brief $'brief body\n' boss "first job" "second job"
    local out; out=$(_launch_worker_on_tty '\r') || { echo "  launch failed: $out"; return 1; }
    assert_output_contains "$out" "\\[Y/n\\]" "consent asked" || return 1
    assert_output_contains "$out" "boss" "spawner shown" || return 1
    assert_output_contains "$out" "first job" "task 1 shown" || return 1
    assert_output_contains "$out" "second job" "task 2 shown" || return 1
    assert_output_contains "$out" "brief:   inline, 11 bytes" "brief shown by size, not as a task" || return 1
    assert_output_not_contains "$out" "3\\. " "the marker and brief are not listed as tasks" || return 1
    assert_eq "2" "$(WQ_COUNT)" "tasks queued after consent" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed after consent" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "brief delivered after consent" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "armed with 2 task(s)" "kick present" || return 1
}

# What the open shows and asks about is what it consumes: a seed replaced in
# .spawn while the ask waits is neither the source of the delivered brief nor
# deleted by the consent given to the first one.
test_launch_consumes_the_seed_it_asked_about() {
    _stage_seed_with_brief $'brief A\n' boss "job A"
    {
        printf '%s\n%s\n%s\n%s\n%s\n' "$OWN_TOKEN" boss "job B" "$BRIEF_MARK" "brief B"
    } > "$TEST_TMPDIR/seed-b"
    local out
    out=$(_launch_worker_on_tty 'y' BEFORE_KEYS="cp '$TEST_TMPDIR/seed-b' '$CS_SESSIONS_ROOT/.spawn/worker.seed'") \
        || { echo "  launch failed: $out"; return 1; }
    assert_eq "brief A" "$(cat "$CS_SESSIONS_ROOT/worker/.cs/brief.md")" "the brief comes from the seed that was shown" || return 1
    assert_eq "job A" "$(WQ_FIRST)" "the task comes from the seed that was shown" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "job B" "the replacement seed is left staged, not consumed" || return 1
}

# A decline answers for the seed that was shown: a seed published in .spawn
# while the ask waits stays staged for its own open, not set aside with it.
test_launch_decline_keeps_a_replacement_seed_staged() {
    _stage_seed_with_brief $'brief A\n' boss "job A"
    {
        printf '%s\n%s\n%s\n' "$OWN_TOKEN" boss "job B"
    } > "$TEST_TMPDIR/seed-b"
    local out
    out=$(_launch_worker_on_tty 'n' BEFORE_KEYS="cp '$TEST_TMPDIR/seed-b' '$CS_SESSIONS_ROOT/.spawn/worker.seed'") \
        || { echo "  launch failed: $out"; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "job B" "the replacement seed stays staged" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "job A" "the declined seed is the one set aside" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing queued after a decline" || return 1
}

# An open stopped at the ask leaves the seed staged for the next open and no
# copy of it anywhere else: the seed can carry a brief.
test_launch_terminated_at_the_ask_leaves_the_seed_staged_and_no_copy() {
    _stage_seed_with_brief $'brief A\n' boss "job A"
    mkdir -p "$TEST_TMPDIR/tmp"
    local out
    out=$(_launch_worker_on_tty '' TMPDIR="$TEST_TMPDIR/tmp" BEFORE_KEYS='kill -TERM $PTY_PID') || true
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "job A" "the seed is staged again" || return 1
    assert_eq "" "$(ls -A "$TEST_TMPDIR/tmp")" "no copy of the seed left in TMPDIR" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT/.spawn" -mindepth 1 ! -name worker.seed)" "nothing else left in .spawn" || return 1
}

# An open stopped after a newer seed took the staged name keeps the newer one
# staged and sets the one it claimed aside.
test_launch_terminated_after_a_newer_seed_sets_the_claimed_one_aside() {
    _stage_seed_with_brief $'brief A\n' boss "job A"
    {
        printf '%s\n%s\n%s\n' "$OWN_TOKEN" boss "job B"
    } > "$TEST_TMPDIR/seed-b"
    local out
    out=$(_launch_worker_on_tty '' BEFORE_KEYS="cp '$TEST_TMPDIR/seed-b' '$CS_SESSIONS_ROOT/.spawn/worker.seed'; kill -TERM \$PTY_PID") || true
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed" "job B" "the newer seed stays staged" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "job A" "the claimed seed is set aside" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT/.spawn" -mindepth 1 -name '.*')" "no claim left in .spawn" || return 1
}

# A launch that fails after it read the seed leaves no copy of it behind.
test_launch_failing_after_the_read_leaves_no_copy_of_the_seed() {
    _launch_worker >/dev/null || return 1
    mkdir "$(WQ)/spawned-by"
    _stage_seed_with_brief $'brief A\n' boss "job A"
    mkdir -p "$TEST_TMPDIR/tmp"
    local rc=0 out
    out=$(TMPDIR="$TEST_TMPDIR/tmp" _launch_worker) || rc=$?
    [ "$rc" != 0 ] || { echo "  launch succeeded with a directory at spawned-by"; return 1; }
    assert_eq "" "$(ls -A "$TEST_TMPDIR/tmp")" "no copy of the seed left in TMPDIR" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT/.spawn" -mindepth 1 -name '.*')" "no launch-owned file left in .spawn" || return 1
}

# A seed whose tasks cannot be written into the queue stops the launch: the
# queue is not armed over nothing, and the seed stays staged for the next open.
test_launch_keeps_the_seed_when_its_tasks_cannot_be_queued() {
    _launch_worker >/dev/null || return 1
    mkdir -p "$(WQ)/queue" "$(WQ)/queue.tmp"
    _stage_seed boss "job A" "job B"
    _deny_writes "$(WQ)/queue.tmp" || return 77
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    _allow_writes "$(WQ)/queue.tmp"
    assert_eq "1" "$rc" "the launch stops" || return 1
    assert_output_contains "$out" "Error: could not write the task into $(WQ)/queue; it is not queued" \
        "the failure names the queue" || return 1
    assert_output_not_contains "$out" "armed with" "no kick announces tasks that were never queued" || return 1
    assert_eq "0" "$(WQ_COUNT)" "no task file landed" || return 1
    assert_file_not_exists "$(WQ)/queue.state" "the queue is not armed" || return 1
    assert_eq "$(printf '%s\nboss\njob A\njob B' "$OWN_TOKEN")" "$(cat "$(SEED)")" "the seed is staged again, whole" || return 1
}

# An open that cannot record the spawner stops before it queues anything, so
# the seed it keeps is the only copy of its tasks: the queue is neither filled
# nor armed, and the retry that follows queues each task once.
# The spawner line becomes the worker's report-back address, in
# .cs/local/spawned-by and in the kick prompt's `cs -msg <spawner>`, so the open
# holds it to cs's session-name rules, as cs -spawn holds the name it writes
# there. A seed whose spawner breaks them is refused before anything is
# written or queued, and stays staged as it was; the refusal names the seed
# and prints the line as a plain name.
test_launch_refuses_a_seed_whose_spawner_is_not_a_session_name() {
    _stage_seed 'boss; cs -rm boss' "job A"
    local staged rc=0 out
    staged=$(cat "$(SEED)")
    out=$(_launch_worker) || rc=$?
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_eq "Error: Spawn seed $(SEED) names a spawner that is not a session name: boss__cs_-rm_boss (seed kept; remove it or re-run cs -spawn, then re-open the session)" \
        "$(tail -1 <<< "$out")" "the refusal names the seed and the spawner line" || return 1
    assert_eq "$staged" "$(cat "$(SEED)")" "the seed is staged again as it was" || return 1
    assert_file_not_exists "$(WQ)/spawned-by" "no spawner is recorded" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing is queued" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick is handed to claude" || return 1
    # A feature session's name, <base>@<task>, is a spawner the rules admit.
    _stage_seed 'boss@review' "job B"
    out=$(_launch_worker) || { echo "  the open over a feature spawner failed: $out"; return 1; }
    assert_eq "boss@review" "$(cat "$(WQ)/spawned-by")" "a feature spawner is recorded" || return 1
    assert_output_contains "$out" "cs -msg boss@review -k result" "a feature spawner gets the reply wiring" || return 1
}

test_launch_that_cannot_record_the_spawner_queues_nothing() {
    _launch_worker >/dev/null || return 1
    mkdir "$(WQ)/spawned-by"
    _stage_seed boss "job A"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_eq "0" "$(WQ_COUNT)" "nothing is queued" || return 1
    assert_file_not_exists "$(WQ)/queue.state" "the queue is not armed" || return 1
    assert_output_contains "$out" "Error: could not record the spawner in $(WQ)/spawned-by (seed kept; fix it and re-open the session to retry)" \
        "the failure names the file" || return 1
    assert_file_exists "$(SEED)" "the seed is staged again" || return 1
    rmdir "$(WQ)/spawned-by"
    _launch_worker >/dev/null || { echo "  the retry failed"; return 1; }
    assert_eq "1" "$(WQ_COUNT)" "the retry queues the task once" || return 1
    assert_eq "job A" "$(WQ_FIRST)" "and it is the seed's task" || return 1
    assert_eq "armed" "$(cat "$(WQ)/queue.state")" "the retry arms the queue" || return 1
    assert_eq "boss" "$(cat "$(WQ)/spawned-by")" "the spawner is recorded" || return 1
}

# A stand-in mv that fails the Nth move into a queue directory, and with
# SEAL_QUEUE set first takes write permission off that directory, so nothing
# already in it can be removed either. Every other move is the real mv's.
_failing_queue_mv() {  # n
    local real_mv; real_mv=$(command -v mv)
    mkdir -p "$TEST_TMPDIR/mvbin"
    cat > "$TEST_TMPDIR/mvbin/mv" <<EOF
#!/bin/sh
case "\$*" in
    */queue/*)
        n=\$(cat "$TEST_TMPDIR/mv.count" 2>/dev/null || echo 0); n=\$((n + 1))
        echo "\$n" > "$TEST_TMPDIR/mv.count"
        if [ "\$n" -ge $1 ]; then
            for last; do :; done
            [ -z "\${SEAL_QUEUE:-}" ] || chmod 500 "\${last%/*}"
            exit 1
        fi ;;
esac
exec "$real_mv" "\$@"
EOF
    chmod +x "$TEST_TMPDIR/mvbin/mv"
}

# A seed whose third task cannot be queued takes back the two this open
# queued before it stops: the seed, staged again, is then the only copy of its
# tasks, and the retry queues each of them once.
test_launch_takes_back_the_tasks_it_queued_when_a_later_one_fails() {
    _launch_worker >/dev/null || return 1
    _stage_seed boss "job A" "job B" "job C"
    _failing_queue_mv 3
    local rc=0 out
    out=$(PATH="$TEST_TMPDIR/mvbin:$PATH" _launch_worker) || rc=$?
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_eq "0" "$(WQ_COUNT)" "the tasks queued before the failure are taken back" || return 1
    assert_output_contains "$out" "Error: could not write the task into $(WQ)/queue; it is not queued (seed kept; the 2 task(s) this open queued before it were taken back)" \
        "the failure says what was taken back" || return 1
    assert_file_not_exists "$(WQ)/queue.state" "the queue is not armed" || return 1
    assert_file_exists "$(SEED)" "the seed is staged again" || return 1
    _launch_worker >/dev/null || { echo "  the retry failed"; return 1; }
    assert_eq "3" "$(WQ_COUNT)" "the retry queues the three tasks" || return 1
    assert_eq "$(printf 'job A\njob B\njob C')" "$(cat "$(WQ)/queue"/* | sort)" "each exactly once" || return 1
}

# A take-back that cannot remove what it queued says so and names each file
# left behind, so the person can remove them before the retry queues them
# again; it never passes the failure off as a clean stop.
test_launch_names_the_tasks_it_could_not_take_back() {
    _launch_worker >/dev/null || return 1
    _stage_seed boss "job A" "job B"
    mkdir -p "$(WQ)/queue"
    _deny_writes "$(WQ)/queue" || return 77
    _allow_writes "$(WQ)/queue"
    _failing_queue_mv 2
    local rc=0 out
    out=$(SEAL_QUEUE=1 PATH="$TEST_TMPDIR/mvbin:$PATH" _launch_worker) || rc=$?
    _allow_writes "$(WQ)/queue"
    assert_eq "1" "$rc" "the open stops" || return 1
    local left; left=$(ls "$(WQ)/queue")
    assert_eq "1" "$(WQ_COUNT)" "the task queued before the failure is still there" || return 1
    assert_output_contains "$out" "Error: could not write the task into $(WQ)/queue; it is not queued, and 1 task(s) this open queued before it could not be taken back: $(WQ)/queue/$left. Remove them before re-opening the session, or the retry queues them again (seed kept)" \
        "the failure names the file left behind" || return 1
    assert_file_exists "$(SEED)" "the seed is staged again" || return 1
}

# The brief is written to the session's .cs/brief.md name itself: a link
# planted there must not turn the delivery into a write over another file.
test_launch_refuses_a_link_at_the_briefs_destination() {
    _launch_worker >/dev/null || return 1
    printf 'project readme\n' > "$CS_SESSIONS_ROOT/worker/README.md"
    ln -s ../README.md "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    _stage_seed_with_brief $'brief body\n' boss "first job"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    [ "$rc" != 0 ] || { echo "  launch succeeded with a link in the brief's place"; return 1; }
    assert_eq "project readme" "$(cat "$CS_SESSIONS_ROOT/worker/README.md")" "the link's target is untouched" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
}

test_launch_foreign_seed_y_consumes() {
    _stage_seed boss "yes job"
    local out; out=$(_launch_worker_on_tty 'y') || { echo "  launch failed: $out"; return 1; }
    assert_eq "1" "$(WQ_COUNT)" "task queued after y" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
}

test_launch_foreign_seed_unknown_key_asks_again() {
    _stage_seed boss "retry job"
    local out; out=$(_launch_worker_on_tty 'xn') || { echo "  launch failed: $out"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "an unknown key is not consent" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "the n after it declined" || return 1
    [ "$(printf '%s' "$out" | grep -c 'Y/n')" -ge 2 ] || { echo "  ask not repeated after an unknown key"; return 1; }
}

test_launch_foreign_seed_escape_declines() {
    _stage_seed boss "escaped job"
    local out; out=$(_launch_worker_on_tty '\x1b') || { echo "  launch failed: $out"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued after Escape" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "Escape set the seed aside" || return 1
}

test_launch_foreign_seed_declined_is_set_aside() {
    _stage_seed_with_brief $'brief body\n' boss "declined job"
    local out; out=$(_launch_worker_on_tty 'n') || { echo "  launch failed: $out"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  declined seed still staged"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "declined seed set aside" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "brief body" "the declined seed keeps its brief" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  brief delivered after a decline"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "nothing queued after a decline" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed after a decline"; return 1; }
    assert_output_not_contains "$out" "armed with" "no kick after a decline" || return 1
    assert_output_contains "$out" "worker.seed.stale" "the launch names where the seed went" || return 1
}

test_launch_seed_control_characters_are_shown_flat() {
    # A hand-crafted seed cannot hold a newline per line, but it can hold
    # other control characters; the consent listing shows them stripped.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '%s\nbo\001ss\nfirst\rjob \033[31mred\n' "$OWN_TOKEN" > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker_on_tty 'n') || { echo "  launch failed: $out"; return 1; }
    assert_output_contains "$out" "boss" "spawner shown flat" || return 1
    assert_output_contains "$out" "firstjob" "task shown flat" || return 1
    assert_output_not_contains "$out" $'\033\[31m' "escape sequence not passed through" || return 1
}

test_launch_token_never_reaches_claude() {
    cat > "$TEST_TMPDIR/fake-claude" << 'FAKE'
#!/usr/bin/env bash
printf 'token=%s\n' "${CS_SPAWN_TOKEN:-unset}"
FAKE
    chmod +x "$TEST_TMPDIR/fake-claude"
    _stage_seed boss "own job"
    local out; out=$(CLAUDE_CODE_BIN="$TEST_TMPDIR/fake-claude" CS_SPAWN_TOKEN="$OWN_TOKEN" "$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "token=unset" "the token is dropped before claude starts" || return 1
}

# Nobody sits at the window cs -spawn opens, so its launch asks nothing about
# a pending release and claude starts. The window's input stays open and
# silent, as a tmux pane's does, where a question waits for good; the run is
# cut at 10 s (status 142). curl answers the signature probe, so the window's
# mark alone keeps the question away. The session still learns the release,
# for its update pane.
test_spawned_window_starts_claude_without_asking_about_an_update() {
    local home="$TEST_TMPDIR/update-home" bin="$TEST_TMPDIR/update-bin" cmd out rc=0
    mkdir -p "$home/.cache/cs" "$bin"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$home/.cache/cs/update-check"
    : > "$home/.cache/cs/update-notes-2026.99.3"
    : > "$home/.cache/cs/update-notes-full-2026.99.3"
    printf '#!/bin/sh\ncase "$*" in *"/download/v2026.99.3/SHA256SUMS.sig -o "*) exit 0 ;; esac\nexit 22\n' > "$bin/curl"
    cat > "$bin/claude" << 'FAKE'
#!/bin/bash
echo "UPDATE_AVAILABLE=${CS_UPDATE_AVAILABLE-unset}"
echo "UPDATE_DECLINED=${CS_UPDATE_DECLINED-unset}"
echo "CS_UNATTENDED=${CS_UNATTENDED-unset}"
FAKE
    chmod +x "$bin/curl" "$bin/claude"
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    cmd=$(sed -n 's/^new-session -d -s cs -n worker -P -F #{window_id} //p' "$FAKE_TMUX_DIR/log")
    [ -n "$cmd" ] || { echo "  FAIL: no window was opened"; cat "$FAKE_TMUX_DIR/log"; return 1; }
    mkfifo "$TEST_TMPDIR/silent"
    exec 5<>"$TEST_TMPDIR/silent"
    out=$(HOME="$home" PATH="$bin:$PATH" CS_NO_UPDATE_CHECK='' CS_ASSUME_TTY=1 CLAUDE_CODE_BIN="$bin/claude" \
        _run_bounded 10 sh -c "$cmd" <&5 2>&1) || rc=$?
    exec 5<&-
    assert_eq "0" "$rc" "the window's launch runs claude to its end" || { echo "$out"; return 1; }
    assert_output_not_contains "$out" "Update now?" "the window is not asked" || return 1
    assert_output_contains "$out" "UPDATE_AVAILABLE=2026.99.3" "the session still learns the release" || return 1
    assert_output_contains "$out" "UPDATE_DECLINED=unset" "nothing is declined on the person's behalf" || return 1
    assert_output_contains "$out" "CS_UNATTENDED=unset" "the window's mark never reaches claude" || return 1
    assert_not_exists "$home/.cache/cs/update-declined" "no declined record" || return 1
}

# An encrypted session keeps its queue behind .cs/private; a seed consumed into
# .cs/local was plaintext the drain never read.
_make_worker_vaulted() {
    local meta="$CS_SESSIONS_ROOT/worker/.cs"
    mkdir -p "$meta/vault-mnt/private"
    mv "$meta/memory" "$meta/vault-mnt/memory"
    mv "$meta/plans" "$meta/vault-mnt/plans"
    ln -s "$meta/vault-mnt/memory" "$meta/memory"
    ln -s "$meta/vault-mnt/plans" "$meta/plans"
    mv "$meta/local/session.log" "$meta/vault-mnt/private/session.log"
    ln -s "$meta/vault-mnt/private" "$meta/private"
}

test_launch_seed_queues_into_the_vault() {
    _launch_worker >/dev/null || return 1
    _make_worker_vaulted
    _stage_seed boss "vault job"
    local out; out=$(_launch_worker) || { echo "  launch failed: $out"; return 1; }
    local priv="$CS_SESSIONS_ROOT/worker/.cs/vault-mnt/private"
    grep -q "vault job" "$priv/queue"/* 2>/dev/null || { echo "  task not queued in the vault"; return 1; }
    assert_file_contains "$priv/queue.state" "armed" "queue armed in the vault" || return 1
    [ ! -e "$(WQ)/queue" ] || { echo "  plaintext queue written beside the vault"; return 1; }
    [ ! -e "$(WQ)/queue.state" ] || { echo "  plaintext queue.state written beside the vault"; return 1; }
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by stays in .cs/local" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
}

run_test test_spawn_rejects_bad_names_and_missing_tmux
run_test test_spawn_rejects_live_target
run_test test_spawn_writes_seed_and_opens_window
run_test test_spawn_without_task_writes_no_seed
run_test test_spawn_rejects_an_invalid_spawner_name
run_test test_spawn_stages_the_brief_inside_the_seed
run_test test_spawn_refuses_a_feature_brief_missing_a_section
run_test test_spawn_accepts_a_complete_feature_brief
run_test test_spawn_reads_feature_brief_sections_as_markdown
run_test test_spawn_brief_and_tasks_stage_together
run_test test_spawn_refuses_a_task_equal_to_the_brief_marker
run_test test_spawn_concurrent_same_name_publishes_one_whole_seed
run_test test_spawn_rejects_unreadable_or_empty_brief_before_staging
run_test test_spawn_failed_brief_copy_publishes_no_seed
run_test test_spawn_a_killed_spawns_staging_file_is_never_published
run_test test_spawn_refuses_to_replace_a_pending_brief
run_test test_spawn_attach_hint_uses_switch_client_inside_tmux
run_test test_spawn_refuses_existing_seed
run_test test_spawn_rejects_multiline_and_empty_task
run_test test_spawn_refuses_unmanaged_cs_session
run_test test_spawn_refuses_duplicate_window
run_test test_spawn_window_command_is_quoted_absolute
run_test test_spawn_refuses_another_sessions_tasks_for_an_existing_session
run_test test_spawn_from_a_terminal_still_hands_an_existing_session_its_tasks
run_test test_spawn_from_the_base_still_briefs_its_existing_feature
run_test test_spawn_accepts_worktree_name
run_test test_spawn_new_session_race_falls_through_to_new_window
run_test test_spawn_tmux_targets_are_exact_match_anchored
run_test test_spawn_empty_spawner_writes_blank_first_line
run_test test_launch_consumes_seed_queues_arms_and_kicks
run_test test_launch_publishes_truecolor_to_the_tmux_session
run_test test_launch_publishes_the_users_truecolor_value
run_test test_launch_publishes_the_sessions_root_to_the_tmux_session
run_test test_launch_outside_tmux_touches_no_tmux_environment
run_test test_launch_empty_spawner_gets_no_reply_wiring
run_test test_launch_without_seed_keeps_color_behavior
run_test test_launch_delivers_the_seeds_brief_and_kicks_to_it
run_test test_launch_ignores_a_brief_file_beside_the_seed
run_test test_launch_brief_with_tasks_kicks_to_both
run_test test_launch_refuses_a_directory_at_the_briefs_destination
run_test test_launch_refuses_a_link_at_the_briefs_destination
run_test test_launch_failed_brief_delivery_keeps_the_seed
run_test test_launch_stale_seed_sets_its_brief_aside_too
run_test test_launch_sets_aside_stale_seed
run_test test_launch_stale_warning_names_the_stale_file
run_test test_launch_fresh_boundary_seed_is_consumed
run_test test_launch_seed_bypasses_resume_ask
run_test test_launch_own_window_consumes_without_asking
run_test test_launch_foreign_seed_unattended_stays_staged
run_test test_launch_wrong_token_is_a_foreign_open
run_test test_launch_seed_without_a_token_line_is_foreign
run_test test_launch_foreign_seed_redirected_stdin_stays_staged
run_test test_launch_foreign_seed_consent_shows_it_and_enter_consumes
run_test test_launch_consumes_the_seed_it_asked_about
run_test test_launch_decline_keeps_a_replacement_seed_staged
run_test test_launch_terminated_at_the_ask_leaves_the_seed_staged_and_no_copy
run_test test_launch_terminated_after_a_newer_seed_sets_the_claimed_one_aside
run_test test_launch_failing_after_the_read_leaves_no_copy_of_the_seed
run_test test_launch_keeps_the_seed_when_its_tasks_cannot_be_queued
run_test test_launch_that_cannot_record_the_spawner_queues_nothing
run_test test_launch_refuses_a_seed_whose_spawner_is_not_a_session_name
run_test test_launch_takes_back_the_tasks_it_queued_when_a_later_one_fails
run_test test_launch_names_the_tasks_it_could_not_take_back
run_test test_launch_foreign_seed_y_consumes
run_test test_launch_foreign_seed_unknown_key_asks_again
run_test test_launch_foreign_seed_escape_declines
run_test test_launch_foreign_seed_declined_is_set_aside
run_test test_launch_seed_control_characters_are_shown_flat
run_test test_launch_token_never_reaches_claude
run_test test_spawned_window_starts_claude_without_asking_about_an_update
run_test test_launch_seed_queues_into_the_vault

# Drain harness (same recipe as tests/test_queue_supervision.sh): the Stop
# hook is stop-blocks.sh; CLAUDE_SESSION_* env selects the session.
_worker_env() {
    CS_LEAD_PID=$$ CLAUDE_PID=$$ \
    CLAUDE_SESSION_NAME="worker" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/worker" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/worker/.cs" \
    "$@"
}
_worker_stop_turn() {
    echo '{}' | PATH="$SCRIPT_DIR/../bin:$PATH" _worker_env bash "$HOOKS_DIR/stop-blocks.sh"
}
_arm_worker_queue() {  # tasks...
    create_test_session worker >/dev/null 2>&1 || true
    create_test_session boss >/dev/null 2>&1 || true
    local t i=0
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/$(printf '%010d' "$i")-seed"
    done
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
}
# First unread message in boss's maildir, as a file path (empty when none).
BOSS_MSG() {
    local f
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || return 1
        printf '%s' "$f"
        return 0
    done
}

# Count of unread messages in boss's maildir.
BOSS_MSG_COUNT() {
    local f n=0
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

test_drain_finished_notifies_spawner_once() {
    _arm_worker_queue "only task"
    _worker_stop_turn >/dev/null || return 1        # armed -> draining, task 1 injected
    _worker_stop_turn >/dev/null || return 1        # task done -> drain_finished
    local msg; msg=$(BOSS_MSG) || { echo "  spawner mail not delivered"; return 1; }
    assert_file_contains "$msg" "queue drained: 1 task(s) done" "notify body" || return 1
    assert_eq "notify" "$(jq -r .kind "$msg")" "kind notify" || return 1
    assert_eq "worker" "$(jq -r .from "$msg")" "from worker" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" ] || { echo "  spawned-by not one-shot"; return 1; }
    # A later, unrelated drain must not re-notify.
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    printf 'later task\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/0000000009-later"
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "1" "$(BOSS_MSG_COUNT)" "no second notify" || return 1
}

test_breaker_trip_notifies_and_keeps_spawned_by() {
    _arm_worker_queue "task a" "task b"
    _worker_stop_turn >/dev/null || return 1        # draining, task a injected
    printf '9\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/failures"
    _worker_stop_turn >/dev/null || return 1        # trips the failure breaker
    local msg; msg=$(BOSS_MSG) || { echo "  trip mail not delivered"; return 1; }
    assert_file_contains "$msg" "breaker tripped" "trip notified" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" "spawned-by kept on trip" || return 1
}

test_drain_without_spawned_by_sends_nothing() {
    _arm_worker_queue "solo task"
    rm -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "0" "$(BOSS_MSG_COUNT)" "notify sent without spawned-by" || return 1
}

run_test test_drain_finished_notifies_spawner_once
run_test test_breaker_trip_notifies_and_keeps_spawned_by
run_test test_drain_without_spawned_by_sends_nothing

report_results
