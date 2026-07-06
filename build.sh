#!/usr/bin/env bash
# ABOUTME: Assembles bin/cs from its lib/*.sh fragments; edit lib/, never bin/cs.
# ABOUTME: Concatenates the numbered fragments in order, dropping each fragment's
# ABOUTME: own ABOUTME header so the built bin/cs keeps only lib/00-header.sh's.
set -euo pipefail
cd "$(dirname "$0")"

LIB_DIR="lib"
OUT="bin/cs"

# The 2-digit numeric prefixes (00,05,10,...,99) give the fragments a total order
# under a plain lexical glob, so the assembled bin/cs is deterministic. Using the
# positional params keeps this portable to macOS's stock bash 3.2 (no mapfile).
set -- "$LIB_DIR"/[0-9]*-*.sh
if [ ! -e "$1" ]; then
    echo "error: no lib/*.sh fragments found in $LIB_DIR/" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

first=1
for f in "$@"; do
    if [ "$first" = 1 ]; then
        # 00-header carries bin/cs's shebang and its single ABOUTME header.
        cat "$f" >> "$tmp"
        first=0
    else
        # Every other fragment documents itself with a leading ABOUTME block for
        # anyone reading lib/; strip that block (and its trailing blank) here so
        # the assembled tool has one header, not nineteen.
        awk 'BEGIN{lead=1}
             lead && /^# ABOUTME:/ {next}
             lead && /^[[:space:]]*$/ {lead=0; next}
             {lead=0; print}' "$f" >> "$tmp"
    fi
done

bash -n "$tmp"
chmod +x "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
echo "Built $OUT from $# lib fragments ($(wc -l < "$OUT") lines)"
