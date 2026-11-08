#!/usr/bin/env bash
# ABOUTME: The shell lint CI runs: shellcheck at error severity over every tracked script,
# ABOUTME: then a warning count that may only fall, held to the number in .shellcheck-warnings.

set -euo pipefail

BASELINE_FILE=".shellcheck-warnings"

_die() {  # message
    printf 'lint_shell: %s\n' "$1" >&2
    exit 2
}

command -v shellcheck > /dev/null || _die "shellcheck is not installed"
[ -f "$BASELINE_FILE" ] || _die "no $BASELINE_FILE here; run from the repo root"
baseline=$(cat "$BASELINE_FILE")
# Nine digits bound the value well inside bash's integer range: past it, the
# comparisons below error out and neither fires, which would read as a pass.
case "$baseline" in
    '' | *[!0-9]* | ??????????*) _die "$BASELINE_FILE must hold a whole number of at most 9 digits, found '$baseline'" ;;
esac

# Every tracked script plus the assembled binaries, which carry no .sh. NUL
# separated, because git quotes a path holding a quote or a control character
# and the quoted form names no file.
files=(bin/cs bin/cs-secrets bin/cs-statusline bin/cs-subagent-statusline)
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(git ls-files -z '*.sh')

# One shellcheck pass at warning severity, which reports errors too, one file
# per run and as many runs at once as there are processors. Each run writes its
# own file, so findings from runs at once never share a write. shellcheck exits
# 1 when it has findings and 2 or more when it could not run (a missing file,
# an unreadable one), so only the latter is a broken lint; a run that hits it
# records the file and its exit for the check below. Under nice, so a fan-out
# across every processor yields to whoever is typing.
out=$(mktemp -d "${TMPDIR:-/tmp}/lint_shell.XXXXXX")
trap 'rm -rf "$out"' EXIT
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
case "$jobs" in '' | *[!0-9]* | 0) jobs=2 ;; esac
printf '%s\0' "${files[@]}" | nice -n 10 xargs -0 -n 1 -P "$jobs" sh -c '
    o=$(mktemp "$1/run.XXXXXX") || exit 255
    rc=0
    shellcheck -S warning -f gcc "$2" > "$o" || rc=$?
    [ "$rc" -le 1 ] || printf "%s (exit %s)\n" "$2" "$rc" > "$o.broken"
' sh "$out" || _die "the parallel shellcheck runs did not finish (xargs exit $?)"
for broken in "$out"/*.broken; do
    [ -e "$broken" ] || continue
    _die "shellcheck could not run on $(cat "$broken")"
done
findings="$out/findings"
cat "$out"/run.* > "$findings"

if grep -q ': error: ' "$findings"; then
    grep ': error: ' "$findings"
    echo "lint_shell: shellcheck found errors (above)" >&2
    exit 1
fi
count=$(wc -l < "$findings" | tr -d ' ')

if [ "$count" -gt "$baseline" ]; then
    echo "shellcheck warnings rose from $baseline to $count. Run shellcheck -S warning on the scripts you changed and fix the new ones." >&2
    exit 1
fi
if [ "$count" -lt "$baseline" ]; then
    echo "shellcheck warnings fell from $baseline to $count. Lower $BASELINE_FILE to $count in this change so the count cannot climb back." >&2
    exit 1
fi
echo "shellcheck warnings: $count (baseline $baseline)"
