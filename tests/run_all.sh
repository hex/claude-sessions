#!/usr/bin/env bash
# ABOUTME: Runs every bash test suite and fails if any suite fails
# ABOUTME: Aggregates per-suite exit codes (a plain for-loop only reports the last)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the suites live. Overridable so the gate's own tests can drive it over a
# directory of fixtures instead of the real suite list -- without the override
# they would glob this directory and recurse into themselves.
SUITE_DIR="${CS_TEST_SUITE_DIR:-$SCRIPT_DIR}"

# --changed: the edit-loop gate. Run only the suites that name a changed path.
# The changed set is the working tree against HEAD plus untracked files, which
# is what "did I break anything" means mid-edit; CS_TEST_CHANGED (one path per
# line) replaces it for callers and for the runner's own tests. A suite is
# selected when its text names the path, or when the path is the suite itself.
# Three kinds of change have no honest subset and run the full gate instead:
# lib/ and bin/cs (bin/cs is assembled from every lib fragment and 45 of 63
# suites invoke it), tests/test_lib.sh (every suite sources it), and any path
# no suite names (an unmapped file is a gap in the map, not a proof of safety).
changed_mode=""
for arg in "$@"; do
    case "$arg" in
        --changed) changed_mode=1 ;;
        *) echo "unknown argument '$arg' (only --changed is accepted)" >&2; exit 2 ;;
    esac
done

# Optional sharding for CI parallelism: CS_TEST_SHARD="N/M" runs shard N of M,
# balanced by line count (see the selection below), so the long suites spread
# across shards. Unset runs every suite. The assignment reads only the suites'
# names and line counts (test_lib.sh is skipped first), so every shard of one
# checkout computes the same assignment and the shards together cover each
# suite exactly once.
shard_n=1; shard_m=1
if [ -n "${CS_TEST_SHARD:-}" ]; then
    shard_n=${CS_TEST_SHARD%%/*}
    shard_m=${CS_TEST_SHARD##*/}
    case "${shard_n}:${shard_m}" in
        *[!0-9]*:*|*:*[!0-9]*|:*|*:) echo "invalid CS_TEST_SHARD='$CS_TEST_SHARD' (want N/M)" >&2; exit 2 ;;
    esac
    if [ "$shard_m" -lt 1 ] || [ "$shard_n" -lt 1 ] || [ "$shard_n" -gt "$shard_m" ]; then
        echo "invalid CS_TEST_SHARD='$CS_TEST_SHARD' (need 1<=N<=M)" >&2; exit 2
    fi
fi

# How many suites run at once. Suites are independent -- test_lib.sh gives every
# test its own mktemp -d and scopes CS_SESSIONS_ROOT, CS_TRANSCRIPTS_DIR, HOME,
# CS_CLAUDE_DIR and CS_TMUX_BIN inside it -- so concurrent suites cannot collide.
# The default is half the cores on a workstation, up to a ceiling. A lane is
# not one process: each suite forks a tree of bash, git and cs, so lanes equal
# to the core count oversubscribe the box several times over (ten lanes on
# fourteen cores drove the load average to 147 and starved the statusline, the
# editor and every other session). Half leaves the other half for the person at
# the keyboard. A small runner (four cores or fewer, the CI shape) has nobody
# at the keyboard and keeps every core: halving it would double the CI lane's
# wall time for no one's benefit. Wall time is the greater of the slowest
# single suite and the total divided by the lanes, so lanes pay off until those
# two meet; the ceiling is where they converge, and past it round-robin
# assignment loses to imbalance. CS_TEST_JOBS overrides; CS_TEST_JOBS=1
# restores a serial run, which streams each suite's output live rather than
# buffering it.
detect_jobs() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -gt 4 ] && n=$((n / 2))
    [ "$n" -ge 1 ] || n=1
    [ "$n" -le 10 ] || n=10
    printf '%s' "$n"
}
if [ -n "${CS_TEST_JOBS:-}" ]; then
    jobs_n="$CS_TEST_JOBS"
    case "$jobs_n" in ''|*[!0-9]*) echo "invalid CS_TEST_JOBS='$CS_TEST_JOBS' (want a positive integer)" >&2; exit 2 ;; esac
    [ "$jobs_n" -ge 1 ] || { echo "invalid CS_TEST_JOBS='$CS_TEST_JOBS' (want a positive integer)" >&2; exit 2; }
else
    jobs_n="$(detect_jobs)"
fi

# How long one suite may run before the gate stops it. Nothing else bounds a
# hung suite: `wait` has no timeout and macOS ships no `timeout`, so a suite
# stuck on a child that never returns holds the whole gate until someone
# notices. The slowest suite, test_install, took 558 to 601 s under a full
# local gate in October 2026 and test_worktrees 476 s, so the default leaves
# test_install about twice its loaded time. CS_TEST_SUITE_TIMEOUT overrides,
# in seconds.
suite_timeout="${CS_TEST_SUITE_TIMEOUT:-1200}"
case "$suite_timeout" in ''|*[!0-9]*) echo "invalid CS_TEST_SUITE_TIMEOUT='$suite_timeout' (want a positive number of seconds)" >&2; exit 2 ;; esac
[ "$suite_timeout" -ge 1 ] || { echo "invalid CS_TEST_SUITE_TIMEOUT='$suite_timeout' (want a positive number of seconds)" >&2; exit 2; }

# Print "weight position" for each file given, heaviest first, ties in the
# order given. A suite's weight is its line count, which stands in for its run
# time: over the 81 suites' CI times in October 2026 the two correlate at 0.79.
# A suite that runs long for its length carries a `# run_all-weight: N` line
# and weighs N times its lines; test_install, whose 3,824 lines took 562 s on
# the macOS runner, would otherwise share a shard with test_worktrees (593 s).
# Both the shard split and the lanes' queue order by it.
_longest_first() {  # file...
    local k=0 f
    for f in "$@"; do
        printf '%s %s\n' "$(awk '/^# run_all-weight: [1-9][0-9]*$/ { w = $3 } END { print NR * (w ? w : 1) }' "$f")" "$k"
        k=$((k + 1))
    done | sort -k1,1nr -k2,2n
}

# Every suite, in glob order.
all=()
for suite in "$SUITE_DIR"/test_*.sh; do
    [ -e "$suite" ] || continue
    # test_lib.sh is the shared harness, not a suite -- it exits non-zero by
    # design when sourced standalone (SCRIPT_DIR guard).
    [ "$(basename "$suite")" = "test_lib.sh" ] && continue
    # An unreadable suite has no line count to place it by; left in, it would
    # drop out of every shard and the gate would pass without running it.
    [ -r "$suite" ] || { echo "cannot read $suite" >&2; exit 2; }
    all+=("$suite")
done

# Select this shard's suites, in glob order. Longest first, each suite goes to
# the shard holding the fewest lines so far (the lowest-numbered on a tie), so
# two long suites never share a shard while another has room. Over October
# 2026's CI times this split two macOS shards at 656 s and 457 s of suite
# time per lane, where a round-robin over names would put test_install and
# test_cs_secrets back to back.
selected=()
if [ "$shard_m" -gt 1 ] && [ "${#all[@]}" -gt 0 ]; then
    load=()
    s=0
    while [ "$s" -lt "$shard_m" ]; do load[s]=0; s=$((s + 1)); done
    mine=" "
    while read -r lines k; do
        best=0
        s=1
        while [ "$s" -lt "$shard_m" ]; do
            [ "${load[s]}" -lt "${load[best]}" ] && best=$s
            s=$((s + 1))
        done
        load[best]=$((load[best] + lines))
        [ "$best" -eq $((shard_n - 1)) ] && mine="$mine$k "
    done <<EOF_SHARDS
$(_longest_first "${all[@]}")
EOF_SHARDS
    k=0
    while [ "$k" -lt "${#all[@]}" ]; do
        case "$mine" in *" $k "*) selected+=("${all[$k]}") ;; esac
        k=$((k + 1))
    done
elif [ "${#all[@]}" -gt 0 ]; then
    selected=("${all[@]}")
fi

if [ -n "$changed_mode" ]; then
    if [ -n "${CS_TEST_CHANGED+set}" ]; then
        changed="$CS_TEST_CHANGED"
    else
        changed=$( { git -C "$SCRIPT_DIR/.." diff --name-only HEAD; git -C "$SCRIPT_DIR/.." ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
    fi
    if [ -z "$changed" ]; then
        echo "nothing changed against HEAD; no suites to run" >&2
        exit 0
    fi
    npaths=$(printf '%s\n' "$changed" | grep -c .)
    full_reason=""
    picked=()
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            lib/*|bin/cs|tests/test_lib.sh|tests/run_all.sh) full_reason="$path"; break ;;
            # Not code: session state, docs, plans, changelog, editor and CI
            # config. A change here proves nothing about the suites, so it
            # neither selects one nor forces the full gate. Skill and command
            # markdown is NOT in this list: suites pin their frontmatter and
            # wording, so those files match by content like any source path.
            # tui/ is the Rust crate: no bash suite reads it, and cargo test
            # covers it separately, so a Rust edit must not drag in all 63.
            .cs/*|.claude*|docs/*|.github/*|.gitignore|assets/*|.superpowers/*|tui/*|README.md|CHANGELOG.md|CONTRIBUTING.md|LICENSE*) continue ;;
        esac
        # One grep across every suite rather than one per (path, suite) pair:
        # the selection runs before any test does, on the gate that exists to
        # be fast.
        hit=""
        for suite in "${selected[@]}"; do
            if [ "tests/${suite##*/}" = "$path" ]; then
                hit=1
                case " ${picked[*]:-} " in *" $suite "*) ;; *) picked+=("$suite") ;; esac
            fi
        done
        while IFS= read -r suite; do
            [ -n "$suite" ] || continue
            hit=1
            case " ${picked[*]:-} " in *" $suite "*) ;; *) picked+=("$suite") ;; esac
        done <<EOF_MATCHED
$(grep -lF -- "$path" "${selected[@]}" 2>/dev/null || true)
EOF_MATCHED
        [ -n "$hit" ] || { full_reason="$path (no suite names it)"; break; }
    done <<EOF_CHANGED
$changed
EOF_CHANGED
    if [ -n "$full_reason" ]; then
        echo "changed: $npaths path(s); $full_reason has no honest subset, running the full gate" >&2
    elif [ "${#picked[@]}" -eq 0 ]; then
        echo "changed: $npaths path(s), none of them code; no suites to run" >&2
        exit 0
    else
        echo "changed: $npaths path(s) select ${#picked[@]} of ${#selected[@]} suites" >&2
        selected=("${picked[@]}")
    fi
fi

total=${#selected[@]}
failed=()

if [ "$total" -eq 0 ]; then
    echo "no suites matched $SUITE_DIR/test_*.sh" >&2
    exit 2
fi

# One gate per checkout. Two full gates on the same box do not overlap, they
# thrash, and a second one started by mistake (a release step beside a manual
# run) is the way a two-minute gate becomes twenty. The lock is a directory
# under the suite dir, taken with mkdir because that is atomic on every
# filesystem cs runs on and needs no flock, which macOS lacks. It holds the
# owner's pid: a live pid means busy, exit 3 so a caller can tell busy from
# failed; a dead pid is a crashed gate's leftover and is taken over.
lock="$SUITE_DIR/.run_all.lock"
_release_lock() {
    [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$lock"
}
if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        echo "another run_all.sh holds $lock (pid $holder); wait for it or stop it" >&2
        exit 3
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "cannot take $lock" >&2; exit 2; }
fi
printf '%s\n' "$$" > "$lock/pid"
trap '_release_lock' EXIT
# A trap runs only after the foreground command returns, so on INT or TERM the
# runner stops the lanes and the suites by pid before exiting through the EXIT
# trap; otherwise a killed gate leaves its suites running and its lock in
# place. Pids, not the process group: a runner started from another script
# shares that script's group, and killing the group would take the caller
# down with it. Each lane records itself in lanes[] and each suite its pid in
# the log dir, which is where _stop_everything finds them.
lanes=()
_stop_everything() {
    trap - INT TERM
    local f
    for f in "$logdir"/*.pid; do
        [ -f "$f" ] && kill -TERM "$(cat "$f" 2>/dev/null)" 2>/dev/null
    done
    [ "${#lanes[@]}" -gt 0 ] && kill -TERM "${lanes[@]}" 2>/dev/null
    exit 130
}
trap '_stop_everything' INT TERM

# Say what the run is about to do. A gate that takes minutes should account for
# them, and the lane count is the one number that explains the wall time.
echo "running $total suites at $jobs_n jobs" >&2

# Every suite's log, exit and wall time land in one scratch directory keyed by
# position, whether the lanes run concurrently or one at a time. Checked,
# because an empty logdir is silently catastrophic rather than noisy: every
# suite is launched with its output redirected into this directory, bash
# abandons a command whose redirection fails, and the missing log then reads as
# a suite that produced no output and did not fail. The gate would report every
# suite passing having run none of them.
logdir="$(mktemp -d)" || { echo "cannot create a scratch directory for the test logs" >&2; exit 2; }
trap 'rm -rf "$logdir"; _release_lock' EXIT
donefile="$logdir/done"
: > "$donefile"

# Run suite k under nice, so a gate yields to whoever is typing: capture its
# output, stamp its seconds and whether it failed, and say so on stderr the
# moment it finishes. The progress counter is the number
# of suites finished so far, not k, so it climbs in finishing order while the
# report below still replays in list order. The one-line append to the done
# file is under PIPE_BUF, so concurrent lanes cannot tear it, and the count is
# read back from that file rather than from a variable a background subshell
# could not share. Serial runs stream straight to the terminal and keep no log:
# nothing replays them.
# One predicate for both halves of the run: whether the suites are actually
# interleaved. Lane count alone is not it — a single selected suite runs serial
# whatever the lane count says, and deciding to capture on one test while
# deciding to replay on another discards that suite's output entirely.
parallel=""
[ "$jobs_n" -gt 1 ] && [ "$total" -gt 1 ] && parallel=1

# A process and everything below it, deepest first. pgrep -P lists direct
# children on macOS and Linux alike.
_descendants() {  # pid
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        _descendants "$child"
    done
    printf '%s\n' "$1"
}

run_suite() {  # index
    # SECONDS and ${x##*/} are builtins: a gate of 63 suites otherwise forks
    # date twice and basename three times per suite for values bash has. Both
    # SECONDS readings come from the same clock date +%s reads, and SECONDS is
    # inherited by a lane subshell rather than reset.
    local k="$1" name t0 secs mark pid
    name="${selected[$k]##*/}"
    t0=$SECONDS
    # The suite runs in the background and is waited on, never in the
    # foreground: wait returns the moment a signal arrives, so the INT/TERM
    # trap can stop the suite by the pid recorded here. Serial runs stream
    # straight through; only interleaved lanes capture to a log.
    # CS_TEST_SKIP_LOG is where the suite's run_test records each skip, so the
    # summary can count them whether or not the output was captured.
    if [ -n "$parallel" ]; then
        CS_TEST_SKIP_LOG="$logdir/$k.skips" nice -n 10 bash "${selected[$k]}" > "$logdir/$k.log" 2>&1 &
    else
        CS_TEST_SKIP_LOG="$logdir/$k.skips" nice -n 10 bash "${selected[$k]}" 2>&1 &
    fi
    pid=$!
    printf '%s\n' "$pid" > "$logdir/$k.pid"
    # The watchdog ticks once a second and leaves on its own as soon as the
    # suite is gone, whether the suite finished or the gate stopped it.
    # A ( ) subshell drops the runner's caught traps, so its exit runs no
    # cleanup; nothing signals it either, so the runner's INT/TERM handler,
    # which removes the log directory and the lock, has no moment right
    # after the fork to run in it. Past the cap, if the suite is still there, it
    # marks the timeout and stops the suite's whole process tree:
    # a hung suite is usually waiting on a grandchild (a test subshell, cs,
    # tmux) that would outlive it. TERM first, KILL for whatever is left
    # after a grace, since a suite can ignore TERM. Pids, not the group, for
    # the reason _stop_everything gives. It writes nothing and its output
    # goes nowhere, so nothing it starts can hold open the pipe a caller
    # reads the gate's output from.
    (
        deadline=$((SECONDS + suite_timeout))
        while [ "$SECONDS" -lt "$deadline" ]; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        : > "$logdir/$k.timeout"
        tree=$(_descendants "$pid")
        kill -TERM $tree 2>/dev/null
        grace=$((SECONDS + 5))
        while [ "$SECONDS" -lt "$grace" ] && kill -0 $tree 2>/dev/null; do
            sleep 1
        done
        kill -KILL $tree 2>/dev/null
    ) > /dev/null 2>&1 &
    wait "$pid" || : > "$logdir/$k.fail"
    rm -f "$logdir/$k.pid"
    # A timeout is a failure whatever the suite's exit: stopping the child it
    # was waiting on can let the suite finish with a clean status.
    if [ -f "$logdir/$k.timeout" ]; then
        : > "$logdir/$k.fail"
        printf '%s: timed out after %ss (CS_TEST_SUITE_TIMEOUT)\n' "$name" "$suite_timeout" >&2
    fi
    secs=$((SECONDS - t0))
    printf '%s\n' "$secs" > "$logdir/$k.secs"
    printf '%s\n' "$k" >> "$donefile"
    mark=""
    [ -f "$logdir/$k.fail" ] && mark=" FAIL"
    printf '[%s/%s] %s %ss%s\n' "$(grep -c . "$donefile")" "$total" "$name" "$secs" "$mark" >&2
}

if [ -n "$parallel" ]; then
    # Each suite writes to its own log keyed by position, so the report below
    # replays them in the same order a serial run would print them -- the
    # concurrency is invisible in the output. Failures are recorded as marker
    # files because a background subshell cannot append to the parent's array.
    # The lanes share one queue: each walks the whole list and runs a suite
    # only when its noclobber open of that position's claim file succeeds: bash's
    # own O_EXCL create, atomic on every filesystem and in no external tool's
    # hands (Ubuntu 26.04's uutils mkdir exits 0 on a racing EEXIST),
    # so every suite runs exactly once and a lane that finishes takes the next
    # unclaimed suite, so no lane idles while another still has a share. The
    # queue holds positions in selected[], longest suite first
    # (_longest_first), so the slowest suites start at once rather than last
    # behind a lane's worth of short ones. Over
    # October 2026's CI times a queue in that order came within a few seconds
    # of the ideal split.
    queue=()
    while read -r _ k; do
        queue+=("$k")
    done <<EOF_QUEUE
$(_longest_first "${selected[@]}")
EOF_QUEUE
    j=0
    while [ "$j" -lt "$jobs_n" ]; do
        (
            q=0
            while [ "$q" -lt "$total" ]; do
                ( set -C; : > "$logdir/$q.claim" ) 2>/dev/null && run_suite "${queue[$q]}"
                q=$((q + 1))
            done
        ) &
        lanes+=("$!")
        j=$((j + 1))
    done
    wait

    k=0
    while [ "$k" -lt "$total" ]; do
        echo "=== ${selected[$k]##*/} ==="
        if [ -f "$logdir/$k.log" ]; then
            cat "$logdir/$k.log"
        else
            # Without this the header prints with an empty body and the run
            # still reports OK, so a lane that died looks like a quiet suite.
            echo "no log captured for ${selected[$k]##*/} — treating as a failure" >&2
            failed+=("${selected[$k]##*/}")
        fi
        [ -f "$logdir/$k.fail" ] && failed+=("${selected[$k]##*/}")
        k=$((k + 1))
    done
else
    k=0
    while [ "$k" -lt "$total" ]; do
        echo "=== ${selected[$k]##*/} ==="
        run_suite "$k"
        [ -f "$logdir/$k.fail" ] && failed+=("${selected[$k]##*/}")
        k=$((k + 1))
    done
fi

# The slow suites get a name. Top of the list is where a minute of wall time
# is hiding; the whole list is what a lane-count change has to be judged by.
echo ""
echo "slowest suites:"
k=0
while [ "$k" -lt "$total" ]; do
    secs=0
    [ -f "$logdir/$k.secs" ] && read -r secs < "$logdir/$k.secs"
    printf '%s %s\n' "${secs:-0}" "${selected[$k]##*/}"
    k=$((k + 1))
done | sort -rn | head -10 | while read -r secs name; do
    printf '  %4ss  %s\n' "$secs" "$name"
done

# A skipped test passes its suite, so a run that judged nothing in a whole
# class of tests (a tool missing on a runner) still reads OK. Name every skip
# here, where CI's last lines show it: the suite, the test and, when
# require_tool skipped it, the missing tool. Each suite's run_test wrote one
# "name<TAB>reason" line per skip to its CS_TEST_SKIP_LOG.
skipped=0
k=0
while [ "$k" -lt "$total" ]; do
    if [ -f "$logdir/$k.skips" ]; then
        while IFS= read -r line; do
            [ "$skipped" -eq 0 ] && printf '\nskipped tests:\n'
            skipped=$((skipped + 1))
            reason=${line#*$'\t'}
            printf '  %s: %s%s\n' "${selected[$k]##*/}" "${line%%$'\t'*}" "${reason:+ ($reason)}"
        done < "$logdir/$k.skips"
    fi
    k=$((k + 1))
done
skip_note=""
[ "$skipped" -eq 1 ] && skip_note=", 1 test skipped"
[ "$skipped" -gt 1 ] && skip_note=", $skipped tests skipped"

echo ""
echo "================================================================"
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${#failed[@]}/$total suites$skip_note"
    for f in "${failed[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo "OK: all $total suites passed$skip_note"
