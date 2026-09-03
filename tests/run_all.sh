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

# Optional sharding for CI parallelism: CS_TEST_SHARD="N/M" runs shard N of M
# (round-robin over the suite list, so slow suites spread across shards). Unset
# runs every suite. The round-robin index counts only real suites (test_lib.sh
# is skipped first), so every shard on an identical runner image computes the
# same assignment and the shards together cover each suite exactly once.
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

# Select this shard's suites, in glob order.
selected=()
idx=-1
for suite in "$SUITE_DIR"/test_*.sh; do
    [ -e "$suite" ] || continue
    # test_lib.sh is the shared harness, not a suite -- it exits non-zero by
    # design when sourced standalone (SCRIPT_DIR guard).
    [ "$(basename "$suite")" = "test_lib.sh" ] && continue
    idx=$((idx + 1))
    if [ "$shard_m" -gt 1 ] && [ "$(( idx % shard_m ))" -ne "$(( shard_n - 1 ))" ]; then
        continue
    fi
    selected+=("$suite")
done

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
    if [ -n "$parallel" ]; then
        nice -n 10 bash "${selected[$k]}" > "$logdir/$k.log" 2>&1 &
    else
        nice -n 10 bash "${selected[$k]}" 2>&1 &
    fi
    pid=$!
    printf '%s\n' "$pid" > "$logdir/$k.pid"
    wait "$pid" || : > "$logdir/$k.fail"
    rm -f "$logdir/$k.pid"
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
    j=0
    while [ "$j" -lt "$jobs_n" ]; do
        (
            k=$j
            while [ "$k" -lt "$total" ]; do
                run_suite "$k"
                k=$((k + jobs_n))
            done
        ) &
        lanes+=("$!")
        j=$((j + 1))
    done
    wait

    k=0
    while [ "$k" -lt "$total" ]; do
        echo "=== ${selected[$k]##*/} ==="
        cat "$logdir/$k.log" 2>/dev/null
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

echo ""
echo "================================================================"
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${#failed[@]}/$total suites"
    for f in "${failed[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo "OK: all $total suites passed"
