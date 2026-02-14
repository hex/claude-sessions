#!/usr/bin/env bash
# ABOUTME: PreCompact hook that archives old discoveries to keep discoveries.md lean
# ABOUTME: Moves oldest entries to discoveries.archive.md when file exceeds MAX_LINES

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Consume stdin (PreCompact provides JSON with transcript_path)
cat > /dev/null

DISCOVERIES_FILE="$META_DIR/discoveries.md"
ARCHIVE_FILE="$META_DIR/discoveries.archive.md"
MAX_LINES=200
KEEP_LINES=100

# Nothing to do if discoveries.md doesn't exist
if [ ! -f "$DISCOVERIES_FILE" ]; then
    exit 0
fi

TOTAL_LINES=$(wc -l < "$DISCOVERIES_FILE" | tr -d ' ')

# Only archive if over threshold
if [ "$TOTAL_LINES" -le "$MAX_LINES" ]; then
    exit 0
fi

# Parse entry boundaries (## headings)
# Build list of line numbers where ## headings appear
HEADING_LINES=()
while IFS= read -r line_num; do
    HEADING_LINES+=("$line_num")
done < <(grep -n "^## " "$DISCOVERIES_FILE" | cut -d: -f1)

# If no ## headings, nothing to split on
if [ ${#HEADING_LINES[@]} -eq 0 ]; then
    exit 0
fi

# Find the split point: keep entries whose ## heading starts at or after
# (TOTAL_LINES - KEEP_LINES). Move everything before that to archive.
SPLIT_LINE=0
for line_num in "${HEADING_LINES[@]}"; do
    if [ "$line_num" -gt $((TOTAL_LINES - KEEP_LINES)) ]; then
        break
    fi
    SPLIT_LINE=$line_num
done

# Find the first heading after SPLIT_LINE -- this is where "keep" begins
KEEP_START=0
for line_num in "${HEADING_LINES[@]}"; do
    if [ "$line_num" -gt "$SPLIT_LINE" ]; then
        KEEP_START=$line_num
        break
    fi
done

# If we couldn't find a good split, bail
if [ "$KEEP_START" -le 1 ]; then
    exit 0
fi

# Extract the header line (# Discoveries & Notes or similar)
HEADER_LINE=$(head -1 "$DISCOVERIES_FILE")

# Lines to archive: from line 2 (after header) to KEEP_START-1
ARCHIVE_END=$((KEEP_START - 1))

# Extract archive content (skip blank lines right after header)
ARCHIVE_CONTENT=$(sed -n "2,${ARCHIVE_END}p" "$DISCOVERIES_FILE")

# Extract keep content (from KEEP_START to end)
KEEP_CONTENT=$(sed -n "${KEEP_START},\$p" "$DISCOVERIES_FILE")

# Append to archive file
if [ -f "$ARCHIVE_FILE" ]; then
    # Add separator between archive batches
    {
        echo ""
        echo "---"
        echo ""
        echo "$ARCHIVE_CONTENT"
    } >> "$ARCHIVE_FILE"
else
    {
        echo "# Discoveries Archive"
        echo ""
        echo "$ARCHIVE_CONTENT"
    } > "$ARCHIVE_FILE"
fi

# Rewrite discoveries.md with header + kept entries
{
    echo "$HEADER_LINE"
    echo ""
    echo "$KEEP_CONTENT"
} > "$DISCOVERIES_FILE"

# Log the rotation
KEPT_LINES=$(wc -l < "$DISCOVERIES_FILE" | tr -d ' ')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$META_DIR/logs"
if [ -d "$LOG_DIR" ]; then
    echo "[$TIMESTAMP] Archived discoveries: ${TOTAL_LINES} lines -> ${KEPT_LINES} kept, rest moved to archive" >> "$LOG_DIR/session.log"
fi

exit 0
