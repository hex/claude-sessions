#!/usr/bin/env bash
# ABOUTME: Assembles bin/cs from its lib/*.sh fragments; edit lib/, never bin/cs.
# ABOUTME: Concatenates the numbered fragments in order, dropping each fragment's
# ABOUTME: own ABOUTME header so the built bin/cs keeps only lib/00-header.sh's.
# ABOUTME: Also writes hooks/cs-shared.sh from lib/02-shared.sh and lib/03-config.sh, the code hooks
# ABOUTME: share with cs, hooks/cs-config.sh from lib/03-config.sh, that fragment into bin/cs-statusline
# ABOUTME: between its two marker lines, and install.sh from install.sh.in with lib/01-manifests.sh
# ABOUTME: spliced in at its marker and the sha256 of every payload file a web install downloads at a second.
set -euo pipefail
cd -- "$(dirname -- "$0")"

LIB_DIR="lib"
OUT="bin/cs"
SHARED_SRC="$LIB_DIR/02-shared.sh"
SHARED_OUT="hooks/cs-shared.sh"
CONFIG_SRC="$LIB_DIR/03-config.sh"
CONFIG_OUT="hooks/cs-config.sh"
STATUSLINE="bin/cs-statusline"
CONFIG_BEGIN='# >>> lib/03-config.sh (spliced by build.sh; edit lib/03-config.sh, never this block)'
CONFIG_END='# <<< lib/03-config.sh'
MANIFESTS_SRC="$LIB_DIR/01-manifests.sh"
INSTALL_TEMPLATE="install.sh.in"
INSTALL_OUT="install.sh"
MARKER='# @@CS_MANIFESTS@@'
SHA_MARKER='# @@CS_PAYLOAD_SHA256@@'

# Adds the sha256 of every file the installer deploys under ~/.claude, as this
# checkout holds it, to CS_KNOWN_SHA256 in lib/01-manifests.sh, keeping the
# table one sha256 per line, sorted and without repeats; a table already
# holding them all is left byte for byte as it was. Refuses a table holding a
# line that is not a sha256 (a comment, a blank line) rather than drop it,
# and an empty table.
add_release_hashes() {
    local table="CS_KNOWN_SHA256" found before after f digest
    found=$(grep -c "^$table=($" "$MANIFESTS_SRC" || true)
    if [ "$found" != 1 ]; then
        echo "error: $MANIFESTS_SRC must carry exactly one '$table=(' line (found $found)" >&2
        exit 1
    fi
    # An empty table is refused here: no cs is without one, and bash 3.2
    # under set -u fails on the empty array expansion below.
    before=$(awk -v start="$table=(" '$0 == start { f = 1; next } f && $0 == ")" { exit } f { n++ } END { print n + 0 }' "$MANIFESTS_SRC")
    if [ "$before" = 0 ]; then
        echo "error: $table in $MANIFESTS_SRC is empty" >&2
        exit 1
    fi
    # Global, not local: the EXIT trap runs after an exit inside this
    # function, and bash 5 runs it without this function's locals.
    merged="$(mktemp)"
    trap 'rm -f "$merged" "$merged.files" "$merged.src"' EXIT
    (
        # shellcheck source=lib/01-manifests.sh
        . "$MANIFESTS_SRC"
        printf '%s\n' "${CS_KNOWN_SHA256[@]}"
        _cs_claude_payload_files > "$merged.files"
        while IFS= read -r f; do
            digest=$(_cs_sha256_file "$f") || {
                echo "error: could not compute the sha256 of payload file $f (missing or unreadable, or no sha256sum or shasum)" >&2
                exit 1
            }
            printf '%s\n' "$digest"
        done < "$merged.files"
    ) | LC_ALL=C sort -u > "$merged"
    if grep -vqx '[0-9a-f]\{64\}' "$merged"; then
        echo "error: $table in $MANIFESTS_SRC holds an entry that is not a sha256: $(grep -vx '[0-9a-f]\{64\}' "$merged" | head -1)" >&2
        exit 1
    fi
    awk -v start="$table=(" -v table="$table" -v merged="$merged" -v src="$MANIFESTS_SRC" '
        state == 0 {
            print
            if ($0 == start) {
                state = 1
                while ((getline line < merged) > 0) print "    " line
                close(merged)
            }
            next
        }
        state == 1 && $0 == ")" { state = 2; print; next }
        state == 1 {
            if ($0 !~ /^    [0-9a-f]+$/ || length($0) != 68) {
                printf "error: %s line %d, inside %s, is not a sha256: %s\n", src, NR, table, $0 > "/dev/stderr"
                bad = 1
            }
            next
        }
        { print }
        END {
            if (state == 1) printf "error: %s has no \")\" line closing %s\n", src, table > "/dev/stderr"
            if (bad || state != 2) exit 1
        }' "$MANIFESTS_SRC" > "$merged.src"
    after=$(wc -l < "$merged")
    if ! cmp -s "$merged.src" "$MANIFESTS_SRC"; then
        chmod 644 "$merged.src"
        mv "$merged.src" "$MANIFESTS_SRC"
    fi
    rm -f "$merged" "$merged.files" "$merged.src"
    trap - EXIT
    echo "$table in $MANIFESTS_SRC: $((after)) sha256s, $((after - before)) added"
}

# ./build.sh builds. ./build.sh --add-release-hashes, run for a release
# commit, first adds that release's payload to CS_KNOWN_SHA256, so an install
# knows the release's files as cs's even when the install record naming them
# is gone. hooks/cs-shared.sh is part of that payload and is built here, so the
# table is extended after a plain build, and the build below folds it into
# bin/cs and install.sh.
case "$#:${1:-}" in
    0:) ;;
    1:--add-release-hashes)
        bash ./build.sh
        add_release_hashes
        ;;
    *)
        echo "error: build.sh takes no argument, or --add-release-hashes (got: $*)" >&2
        exit 1
        ;;
esac

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
chmod 755 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
echo "Built $OUT from $# lib fragments ($(wc -l < "$OUT") lines)"

# The hooks cannot source lib/ (they run from ~/.claude/hooks/cs/, where only
# the hooks and their libraries are deployed), so the fragments they share with
# cs ship beside them as libraries, byte-for-byte the lib/ files under a
# shebang: cs-shared.sh carries both, and cs-config.sh the settings loader
# alone, for a hook or a child script that reads a setting before (or without)
# sourcing cs-shared.sh. CI's build-sync job diffs both: they are generated,
# never hand-edited.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
    echo '#!/usr/bin/env bash'
    echo "# Generated by build.sh from $SHARED_SRC and $CONFIG_SRC. Edit those files, never this one."
    cat "$SHARED_SRC" "$CONFIG_SRC"
} > "$tmp"
bash -n "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$SHARED_OUT"
trap - EXIT
echo "Built $SHARED_OUT from $SHARED_SRC and $CONFIG_SRC"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
    echo '#!/usr/bin/env bash'
    echo "# Generated by build.sh from $CONFIG_SRC. Edit that file, never this one."
    cat "$CONFIG_SRC"
} > "$tmp"
bash -n "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$CONFIG_OUT"
trap - EXIT
echo "Built $CONFIG_OUT from $CONFIG_SRC"

# The status line runs every repaint under a first-tick budget and sources no
# library (it cannot find the hooks directory from where Claude Code runs it),
# so the settings loader is spliced into it, between two marker lines, without
# the fragment's ABOUTME header. Everything outside the markers is hand-edited
# and kept byte for byte. A file without exactly one of each marker would
# take a second copy, or none, and bash -n passes both.
for marker in "$CONFIG_BEGIN" "$CONFIG_END"; do
    marker_count=$(grep -cxF -- "$marker" "$STATUSLINE" || true)
    if [ "$marker_count" != 1 ]; then
        echo "error: $STATUSLINE must carry exactly one '$marker' line (found $marker_count)" >&2
        exit 1
    fi
done
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v begin="$CONFIG_BEGIN" -v end="$CONFIG_END" -v src="$CONFIG_SRC" '
    $0 == begin {
        print
        lead = 1
        while ((getline line < src) > 0) {
            if (lead && line ~ /^# ABOUTME:/) continue
            if (lead && line ~ /^[[:space:]]*$/) { lead = 0; continue }
            lead = 0
            print line
        }
        close(src)
        skip = 1
        next
    }
    $0 == end { skip = 0 }
    !skip { print }' "$STATUSLINE" > "$tmp"
bash -n "$tmp"
if cmp -s "$tmp" "$STATUSLINE"; then
    rm -f "$tmp"
else
    chmod 755 "$tmp"
    mv "$tmp" "$STATUSLINE"
fi
trap - EXIT
echo "Spliced $CONFIG_SRC into $STATUSLINE"

# install.sh runs from a curl pipe on a web install and can source nothing, so
# the manifests it shares with cs (which hooks, commands, skills and mods to
# deploy, and the settings-strip filter) are spliced into it at build time,
# at the template's one marker line. A template with no marker, or two, would
# build an installer with no manifests or two, and `bash -n` passes both.
marker_count=$(grep -c "^${MARKER}\$" "$INSTALL_TEMPLATE" || true)
if [ "$marker_count" != 1 ]; then
    echo "error: $INSTALL_TEMPLATE must carry exactly one '$MARKER' line (found $marker_count)" >&2
    exit 1
fi
sha_marker_count=$(grep -c "^${SHA_MARKER}\$" "$INSTALL_TEMPLATE" || true)
if [ "$sha_marker_count" != 1 ]; then
    echo "error: $INSTALL_TEMPLATE must carry exactly one '$SHA_MARKER' line (found $sha_marker_count)" >&2
    exit 1
fi
# awk's getline reads a missing file as an empty one and exits 0, and an
# installer with no manifests passes bash -n; the source is checked first.
if [ ! -r "$MANIFESTS_SRC" ]; then
    echo "error: $MANIFESTS_SRC is missing or unreadable; nothing to splice into $INSTALL_OUT" >&2
    exit 1
fi

# A web install checks every file it downloads against these sha256s, so the
# table is of the files this build leaves in the checkout: bin/cs and
# hooks/cs-shared.sh as just built above, the rest as committed. CI's
# build-sync job then fails any commit that changes a payload file without
# rebuilding install.sh. The list of files is the manifests' own.
sha_table="$(mktemp)"
trap 'rm -f "$sha_table" "$sha_table.files"' EXIT
(
    # shellcheck source=lib/01-manifests.sh
    . "$MANIFESTS_SRC"
    _cs_payload_files
    printf '%s\n' "${CS_COMPLETION_FILES[@]}"
) > "$sha_table.files"
{
    echo "CS_PAYLOAD_SHA256=("
    while IFS= read -r f; do
        [ -f "$f" ] || { echo "error: payload file $f is missing" >&2; exit 1; }
        if command -v sha256sum > /dev/null 2>&1; then
            digest=$(sha256sum < "$f")
        else
            digest=$(shasum -a 256 < "$f")
        fi
        echo "    \"${digest%% *}  $f\""
    done < "$sha_table.files"
    echo ")"
} > "$sha_table"
rm -f "$sha_table.files"

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$sha_table"' EXIT
awk -v marker="$MARKER" -v src="$MANIFESTS_SRC" -v sha_marker="$SHA_MARKER" -v sha_table="$sha_table" '
    NR == 2 { print "# Generated by build.sh from install.sh.in and " src ". Edit those, never this file." }
    $0 == sha_marker {
        while ((getline line < sha_table) > 0) print line
        close(sha_table)
        next
    }
    $0 == marker {
        print "# ---- " src " (spliced by build.sh) ----"
        lead = 1
        while ((getline line < src) > 0) {
            if (lead && line ~ /^# ABOUTME:/) continue
            if (lead && line ~ /^[[:space:]]*$/) { lead = 0; continue }
            lead = 0
            print line
        }
        close(src)
        print "# ---- end " src " ----"
        next
    }
    { print }' "$INSTALL_TEMPLATE" > "$tmp"
bash -n "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$INSTALL_OUT"
rm -f "$sha_table"
trap - EXIT
echo "Built $INSTALL_OUT from $INSTALL_TEMPLATE + $MANIFESTS_SRC"
