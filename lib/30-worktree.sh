# ABOUTME: Parallel feature worktrees: name parsing, bootstrap, create, merge, and record fusion.
# ABOUTME: Backs 'cs <base>@<feature>' and the finish skill's integrate and retire entries.

cs_split_worktree_name() {
    local name="$1"
    case "$name" in
        *@*) ;;
        *) return 1 ;;
    esac
    CS_WT_BASE="${name%%@*}"
    CS_WT_TASK="${name#*@}"
    if [ -z "$CS_WT_BASE" ]; then
        error "Session name cannot be empty before '@' (expected <base>@<feature>)"
    fi
    validate_session_name "$CS_WT_BASE"
    case "$CS_WT_TASK" in
        .*) error "Worktree feature name cannot start with a dot" ;;
    esac
    _feature_name_ok "$CS_WT_TASK" \
        || error "Worktree feature name must contain only alphanumeric characters, hyphens, underscores, and dots"
    return 0
}

# Whether <task> is a feature name cs accepts: alphanumerics, hyphens,
# underscores and dots, never a leading dot. The feature half names the branch
# cs/<feature>, and git refuses a ref component that starts with a dot; the
# record fuse names a directory in the base's .cs after it.
_feature_name_ok() {  # task
    case "$1" in
        .*|'') return 1 ;;
    esac
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# Create the .cs/ skeleton inside a worktree whose repo does not track .cs/
# (ignored mode). Leaves the checkout's CLAUDE.md alone — in these repos it
# is the project's own tracked file.
bootstrap_worktree_meta() {
    local wt_dir="$1" base_name="$2" task="$3" base_dir="$4"
    mkdir -p "$wt_dir/.cs"/{local,memory}
    _copy_base_context "$base_dir/.cs" "$wt_dir/.cs"
    _write_session_readme_head "$wt_dir/.cs/README.md" "$base_name@$task" "[worktree]" "[\"$base_name@$task\"]"
    cat >> "$wt_dir/.cs/README.md" << EOF
Feature worktree of session '$base_name' on branch cs/$task.

## Objective

[Describe this feature]
EOF
    _record_inherited "$wt_dir/.cs" README.md
    cat > "$wt_dir/.cs/local/session.log" << EOF
Claude Code Session Log
Session: $base_name@$task
Started: $(date '+%Y-%m-%d %H:%M:%S')

================================================================================

EOF
    ensure_narrative_file "$wt_dir"
}

# Give an ignored-mode feature the base's context, which git cannot carry:
# the memory topics, the MEMORY.md index, plans/ and summary.md. Never a
# narrative (the feature keeps its own and fusion appends it back), .cs/local,
# a lock or the timeline. A symlink is skipped, not followed: it would copy
# whatever it points at into the feature. plans/ is copied file by file for
# the same reason, so a link inside it (to another session's plans, say) stays
# behind; only regular files come over. A failed copy warns and the create
# goes on; the feature only starts with less context.
# Each file copied is recorded (_record_inherited), so the fuse can tell a
# file the feature edited from the copy it was handed.
_copy_base_context() {  # base_meta wt_meta
    local src="$1" dst="$2" f name
    for f in "$src"/memory/*.md; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        name="${f##*/}"
        case "$name" in narrative.*.md|narrative.md) continue ;; esac
        if ! cp "$f" "$dst/memory/$name"; then
            warn "could not copy memory/$name from the base"
            continue
        fi
        _record_inherited "$dst" "memory/$name"
    done
    if [ -d "$src/plans" ] && [ ! -L "$src/plans" ]; then
        local rel parent
        mkdir -p "$dst/plans" || warn "could not create plans/ in the feature"
        # find -P (the default) never descends a linked dir, and -type f
        # leaves out links and specials.
        (cd -- "$src/plans" && find . -type f -print0) | while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            # Parameter expansion, not dirname: a "-sub" component reads as an
            # option to it, and $( ) drops a trailing newline from a name.
            parent=.
            case "$rel" in */*) parent="${rel%/*}" ;; esac
            if { mkdir -p "$dst/plans/$parent" && cp "$src/plans/$rel" "$dst/plans/$rel"; }; then
                _record_inherited "$dst" "plans/$rel"
            else
                warn "could not copy plans/$rel from the base"
            fi
        done || warn "could not list plans/ in the base"
    fi
    if [ -f "$src/summary.md" ] && [ ! -L "$src/summary.md" ]; then
        if cp "$src/summary.md" "$dst/summary.md"; then
            _record_inherited "$dst" summary.md
        else
            warn "could not copy summary.md from the base"
        fi
    fi
    return 0
}

# Where a feature's .cs keeps the record of one file the create put there,
# for a path relative to .cs: a top-level memory topic at
# local/inherited-topics/<name>, any other file at local/inherited/<path>. Sets
# _CS_INHERITED_RECORD rather than printing it, since $( ) would drop a
# trailing newline from a name.
_inherited_record_path() {  # meta rel
    case "$2" in
        memory/*/*) _CS_INHERITED_RECORD="$1/local/inherited/$2" ;;
        memory/*) _CS_INHERITED_RECORD="$1/local/inherited-topics/${2#memory/}" ;;
        *) _CS_INHERITED_RECORD="$1/local/inherited/$2" ;;
    esac
}

# Record a file the create just put in a feature's .cs, a copy of the base's
# or one cs wrote, as its "<cksum> <bytes>". One record file per file: the
# file system keeps any name whole, and nothing has to parse one. A record
# that cannot be written warns and the create goes on; the fuse then takes the
# file for one the feature wrote, which refuses rather than overwrites.
_record_inherited() {  # meta rel
    local sum
    _inherited_record_path "$1" "$2"
    sum=$(cksum < "$1/$2") \
        && mkdir -p "${_CS_INHERITED_RECORD%/*}" \
        && printf '%s\n' "$sum" > "$_CS_INHERITED_RECORD" \
        || warn "could not record $2 as inherited from the base"
    return 0
}

# True when a checkout has uncommitted changes to tracked files (staged or
# unstaged). Untracked files are a separate question with per-site messages.
_tree_is_dirty() {
    ! git -C "$1" diff --quiet 2>/dev/null \
        || ! git -C "$1" diff --cached --quiet 2>/dev/null
}

# The names `git ls-files -z` prints, read on stdin, one per line. A name may
# hold any byte, so a backslash in one is written "\\" and a newline "\n":
# each line stands for exactly one name, and printf's %b gives the name back.
# Names are bytes, whatever the locale. Fails without perl, as the session
# lock does.
_names_as_lines() {
    perl -0 -ne 'BEGIN { binmode STDIN; binmode STDOUT }
                 chomp; s/\\/\\\\/g; s/\n/\\n/g; print "$_\n"'
}

# The awk function printable(name): the name as a message prints it, each
# control character in it (a newline, an escape, a carriage return, or a C1
# control, U+0080 to U+009F, which a terminal may obey as an escape) as one
# "?", so no name can break a line or drive the terminal, and each character
# that flips the direction of the text after it (U+202A to U+202E, U+2066 to
# U+2069, U+200E, U+200F, U+061C) or takes no room (U+200B to U+200D,
# U+2060, U+FEFF) as one "?", so no name can read as another file's. Every
# other character, an accent or a space, prints as itself, as does a byte
# that starts none of those. Run under LC_ALL=C: names are bytes whatever
# the locale, and each character past ASCII is matched by its whole UTF-8
# sequence. _printable_name and _untracked_listing_format both print names
# with it.
_CS_PRINTABLE_AWK='
function printable(name) {
    gsub(/[[:cntrl:]]/, "?", name)
    gsub(/\302[\200-\237]|\342\200[\213-\217\252-\256]|\342\201[\240\246-\251]|\330\234|\357\273\277/, "?", name)
    return name
}'

# A name as a message prints it (printable in _CS_PRINTABLE_AWK). The name
# goes to awk on stdin, so its length has no limit; awk reads it as lines,
# and each newline between them prints as "?", as printable prints it.
_printable_name() {  # name
    printf '%s\n' "$1" | env LC_ALL=C awk "$_CS_PRINTABLE_AWK"'
        { out = out (NR > 1 ? "?" : "") printable($0) }
        END { printf "%s", out }'
}

# Tracked files marked skip-worktree or assume-unchanged whose working copy
# differs from the index, one per line, each path as a message prints it
# (_printable_name): git diff hides these edits and git
# keeps no copy of them, so removing a worktree destroys them. Checked on a
# worktree about to be removed only; in a base the flags usually mark local
# config the user means to keep uncommitted. A link counts by its target, as
# git stores it, and a link where the index has a file (or the reverse) is an
# edit. A file the flag leaves absent (sparse checkout) holds no edit. An
# initialised submodule keeps an index of its own: its hidden edits are listed
# too, at any depth, each path prefixed with <prefix>, the submodule's path.
# Fails when git cannot list an index, never answering "none" on a listing it
# did not get.
_hidden_tracked_edits() {  # checkout_dir [prefix]
    local entry tag mode oid path now target
    git -C "$1" ls-files -v -s -z > /dev/null 2>&1 || return 1
    # Each entry reads "<tag> <mode> <oid> <stage>\t<path>".
    while IFS= read -r -d '' entry; do
        tag="${entry%% *}"
        entry="${entry#* }"
        mode="${entry%% *}"
        entry="${entry#* }"
        oid="${entry%% *}"
        path="${entry#*$'\t'}"
        if [ "$mode" = 160000 ]; then
            [ -e "$1/$path/.git" ] || continue
            _hidden_tracked_edits "$1/$path" "${2:-}$(_printable_name "$path")/" || return 1
            continue
        fi
        case "$tag" in S|[[:lower:]]) ;; *) continue ;; esac
        if [ -L "$1/$path" ]; then
            if [ "$mode" = 120000 ]; then
                target=$(readlink -n "$1/$path" && printf x) || target=""
                now=$(printf '%s' "${target%x}" | git -C "$1" hash-object --stdin 2>/dev/null) || now=""
            else
                now=""
            fi
        elif [ -f "$1/$path" ]; then
            if [ "$mode" != 120000 ]; then
                now=$(git -C "$1" hash-object -- "$path" 2>/dev/null) || now=""
            else
                now=""
            fi
        else
            continue
        fi
        [ "$now" = "$oid" ] || printf '%s%s\n' "${2:-}" "$(_printable_name "$path")"
    done < <(git -C "$1" ls-files -v -s -z 2>/dev/null)
    return 0
}

# The paths of a worktree given one per line on stdin, without cs's own
# bookkeeping. cs writes it into every worktree — .cs/local, the session
# locks, the settings and protocol files — and none of it is the user's to
# commit; the removal passes --force precisely because these are expected. In
# ignored mode the whole .cs tree is left to _fuse_conflicts, which knows what
# the record fuse carries. In tracked mode git carries .cs, so any other
# untracked file there is at risk like one anywhere else. Finder's .DS_Store
# is no one's work either, as cs -rm also treats it.
_without_cs_bookkeeping() {  # wt_dir
    local -a cs_own=(-e '^\.cs/')
    if [ "$(_read_local_state "$1/.cs/local/state" cs_mode)" != "ignored" ]; then
        cs_own=(-e '^\.cs/local/' -e '^\.cs/session\.lock$' -e '^\.cs/session\.mutex\.lock$'
                -e '^\.cs/\.narrative-reminder-cooldown$')
    fi
    # The protocol file is cs's only while it carries cs's sentinel; one
    # without it is the user's own (ensure_session_claude_md draws the same line).
    if grep -qF '<!-- cs:session-protocol -->' "$1/CLAUDE.local.md" 2>/dev/null; then
        cs_own+=(-e '^CLAUDE\.local\.md$')
    fi
    env LC_ALL=C grep -v "${cs_own[@]}" -e '^\.claude/settings\.local\.json$' \
        -e '^\.DS_Store$' -e '/\.DS_Store$' \
        || [ $? -eq 1 ]
}

# Paths in a worktree's own checkout that git does not track, one per line
# (_names_as_lines), without cs's own bookkeeping: with --ignored the paths
# git ignores, else the untracked ones it does not. git lists nothing inside
# a submodule; _submodule_others does.
_worktree_others() {  # wt_dir [--ignored]
    # -z, then one name per line (_names_as_lines): without -z git quotes any
    # name holding a newline or a non-ASCII byte, and the quote in front
    # hides cs's own files from the patterns of _without_cs_bookkeeping. A
    # listing that fails is a failure, never an empty list: the caller would
    # remove the worktree on it.
    local listing
    listing=$(git -C "$1" ls-files -z --others ${2:+"$2"} --exclude-standard 2>/dev/null \
              | _names_as_lines) || return 1
    [ -n "$listing" ] || return 0
    printf '%s\n' "$listing" | _without_cs_bookkeeping "$1"
}

# The untracked and ignored files inside every initialised submodule of a
# checkout, at any depth, one per line (_names_as_lines), each path prefixed
# with <prefix> and its submodule's path. git ls-files never lists the files
# inside a submodule: it is a checkout of its own, and removing the worktree
# removes it with them. A submodule the checkout never populated is an empty
# directory to git, which lists nothing inside it either, so every file
# there is listed. Fails when any listing fails.
_submodule_others() {  # checkout_dir prefix
    local entry sub at listing line
    git -C "$1" ls-files -s -z > /dev/null 2>&1 || return 1
    # A gitlink's index entry reads "160000 <oid> <stage>\t<path>"; one with a
    # .git inside is initialised.
    while IFS= read -r -d '' entry; do
        case "$entry" in 160000\ *) ;; *) continue ;; esac
        sub="${entry#*$'\t'}"
        if [ ! -e "$1/$sub/.git" ]; then
            [ -d "$1/$sub" ] && [ ! -L "$1/$sub" ] || continue
            at=$(printf '%s\0' "$sub" | _names_as_lines) || return 1
            listing=$( (cd -- "$1/$sub" && find . ! -type d -print0) | _names_as_lines) || return 1
            if [ -n "$listing" ]; then
                while IFS= read -r line; do
                    printf '%s%s/%s\n' "$2" "$at" "${line#./}"
                done <<< "$listing"
            fi
            continue
        fi
        at=$(printf '%s\0' "$sub" | _names_as_lines) || return 1
        listing=$({ git -C "$1/$sub" ls-files -z --others --exclude-standard \
                    && git -C "$1/$sub" ls-files -z --others --ignored --exclude-standard; } 2>/dev/null \
                  | _names_as_lines) || return 1
        if [ -n "$listing" ]; then
            while IFS= read -r line; do
                printf '%s%s/%s\n' "$2" "$at" "$line"
            done <<< "$listing"
        fi
        _submodule_others "$1/$sub" "$2$at/" || return 1
    done < <(git -C "$1" ls-files -s -z 2>/dev/null)
    return 0
}

# The path of every submodule of a checkout, at any depth, populated or not,
# one per line (_names_as_lines) with "/" after it and <prefix> before it:
# git ls-files --recurse-submodules leaves out one that holds no file, and a
# listing must never collapse it or a directory above it. Fails when git
# cannot list an index.
_submodule_dirs() {  # checkout_dir prefix
    local entry sub at
    git -C "$1" ls-files -s -z > /dev/null 2>&1 || return 1
    while IFS= read -r -d '' entry; do
        case "$entry" in 160000\ *) ;; *) continue ;; esac
        sub="${entry#*$'\t'}"
        at=$(printf '%s\0' "$sub" | _names_as_lines) || return 1
        printf '%s%s/\n' "$2" "$at"
        [ -e "$1/$sub/.git" ] || continue
        _submodule_dirs "$1/$sub" "$2$at/" || return 1
    done < <(git -C "$1" ls-files -s -z 2>/dev/null)
    return 0
}

# Files in a worktree that removal would destroy and the retire refuses over,
# one per line (_names_as_lines), without cs's own bookkeeping: the untracked
# files git does not ignore, work the user has not committed, and every
# untracked or ignored file inside an initialised submodule, and every file
# inside a submodule directory the worktree never populated. The ignored
# files of the worktree's own checkout are not among them: the retire trashes
# those or deletes them with the worktree (_retire_trash_ignored_work). The
# one exception is a root CLAUDE.local.md of the user's own: cs's exclude is
# what ignores that name, not a choice of theirs, so it is at risk whether
# git ignores it or not.
# The merge gate and the readiness screen MUST read from this one definition;
# when they disagreed, a worktree predating the cs exclude reported blocked on a
# merge that would have gone straight through.
_worktree_untracked_at_risk() {  # wt_dir
    local listing more
    listing=$(git -C "$1" ls-files -z --others --exclude-standard 2>/dev/null \
              | _names_as_lines) || return 1
    more=$(git -C "$1" ls-files -z --others --ignored --exclude-standard -- CLAUDE.local.md 2>/dev/null \
           | _names_as_lines) || return 1
    [ -z "$more" ] || listing="${listing:+$listing$'\n'}$more"
    more=$(_submodule_others "$1" "") || return 1
    [ -z "$more" ] || listing="${listing:+$listing$'\n'}$more"
    [ -n "$listing" ] || return 0
    printf '%s\n' "$listing" | _without_cs_bookkeeping "$1"
}

# Directory names whose contents a build, an install or a test run writes
# again: an ignored file under one of these, at any depth, goes with a retired
# worktree. Every other ignored file goes to the system trash instead.
CS_REGENERABLE_DIRS=(
    node_modules .svelte-kit .next .nuxt .output .turbo .parcel-cache .vite .astro .angular
    coverage .nyc_output htmlcov
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .venv venv .hypothesis
    target .gradle .dart_tool .direnv
    test-results playwright-report
)

# Bytes of paths one call of the trash command gets. The system refuses to
# run a command line longer than its limit (1 MiB on macOS, 2 MiB on Linux,
# the environment and a pointer per argument included), so a long list goes
# over several calls. 128 KiB is the size GNU xargs builds by default: an
# eighth of the smaller limit, which leaves the rest to the environment.
CS_TRASH_CALL_BYTES=131072

# The paths given one per line on stdin that lie under a regenerable
# directory (keep=regenerable) or that do not (keep=other). A path's last
# component is its own name, so only the directories above it count.
_regenerable_filter() {  # regenerable|other
    env LC_ALL=C awk -F/ -v keep="$1" -v names="${CS_REGENERABLE_DIRS[*]}" '
        BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) regenerable[list[i]] = 1 }
        {
            under = 0
            for (i = 1; i < NF; i++) if ($i in regenerable) { under = 1; break }
            if (under == (keep == "regenerable")) print
        }'
}

# The system trash command, one word per line: macOS's trash, else GLib's
# gio trash. Prints nothing when neither is installed.
_system_trash_command() {
    if command -v trash >/dev/null 2>&1; then
        echo trash
    elif command -v gio >/dev/null 2>&1; then
        printf '%s\n' gio trash
    fi
}

# The entries of a listing of files a removal would destroy, from three
# lists on stdin separated by empty lines: the checkout's paths that stay
# (tracked, or deleted anyway); "<count><TAB><path>" for each directory git
# does not list into (a nested repository, shown by git as one path ending in
# "/"); and the paths at risk. Each path is a line of _names_as_lines, so two
# names are one entry only when they are the same name. A directory holding
# no path that stays is one entry with the number of files at risk under it,
# any other path is an entry alone. Prints "<files><TAB><entry>", the entries
# holding the most files first, then by path as its line is written.
_untracked_entries() {
    local tab=$'\t'
    env LC_ALL=C awk '
        BEGIN { section = 0 }
        $0 == "" { section++; next }
        section == 0 {
            dir = $0
            if (!sub(/\/[^\/]*$/, "/", dir) || (dir in tracked)) next
            n = split(dir, seg, "/")
            dir = ""
            for (i = 1; i < n; i++) { dir = dir seg[i] "/"; tracked[dir] = 1 }
            next
        }
        section == 1 {
            cut = index($0, "\t")
            inside[substr($0, cut + 1)] = substr($0, 1, cut - 1)
            next
        }
        {
            files = 1
            if ($0 ~ /\/$/) {
                if (!($0 in inside)) { unknown = $0; exit }
                files = inside[$0]
            }
            entry = $0
            n = split($0, seg, "/")
            dir = ""
            for (i = 1; i < n; i++) {
                dir = dir seg[i] "/"
                if (!(dir in tracked)) { entry = dir; break }
            }
            count[entry] += files
        }
        END {
            if (unknown != "") {
                printf "no file count for the directory %s\n", unknown > "/dev/stderr"
                exit 1
            }
            for (entry in count) printf "%d\t%s\n", count[entry], entry
        }' \
    | env LC_ALL=C sort -t "$tab" -k1,1nr -k2
}

# The listing of the entries on stdin (_untracked_entries): the count phrase
# ("1 file", "60,882 files"), then one line per entry indented four spaces, a
# directory with its file count in a column past the longest directory
# shown. With a number, at most that many entries, then how many are not
# shown; with "all", every entry. An entry prints as its name as a message
# prints it (printable in _CS_PRINTABLE_AWK), after the directory given as
# $2, if any.
_untracked_listing_format() {  # shown|all [directory]
    env LC_ALL=C CS_LISTING_DIRECTORY="${2:-}" awk -v shown="$1" "$_CS_PRINTABLE_AWK"'
        function grouped(n,    s) {
            s = sprintf("%d", n)
            while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", s)
            return s
        }
        function files(n) { return grouped(n) (n == 1 ? " file" : " files") }
        # The name a line stands for (_names_as_lines) as a message prints
        # it: its newline, written "\n" on the line, as "?" like each other
        # control character (printable).
        function printed(line,    name, at) {
            name = ""
            while ((at = index(line, "\\")) > 0) {
                name = name substr(line, 1, at - 1) (substr(line, at + 1, 1) == "n" ? "?" : "\\")
                line = substr(line, at + 2)
            }
            return printable(name line)
        }
        # The characters in a name, each taken as one column: names are bytes
        # here, and a UTF-8 character is every byte but those that continue
        # one (\200 to \277).
        function columns(name) {
            gsub(/[\200-\277]/, "", name)
            return length(name)
        }
        BEGIN { if (shown == "all") shown = -1 }
        {
            cut = index($0, "\t")
            total += substr($0, 1, cut - 1)
            if (shown >= 0 && NR > shown) next
            held[NR] = substr($0, 1, cut - 1)
            path[NR] = ENVIRON["CS_LISTING_DIRECTORY"] printed(substr($0, cut + 1))
            if (path[NR] ~ /\/$/ && columns(path[NR]) > width) width = columns(path[NR])
        }
        END {
            print files(total)
            for (i = 1; i <= NR && (shown < 0 || i <= shown); i++) {
                # printf pads by bytes, so the column is widened by the bytes
                # that are no character of their own.
                if (path[i] ~ /\/$/) printf "    %-" (width + length(path[i]) - columns(path[i])) "s  (%s)\n", path[i], files(held[i])
                else printf "    %s\n", path[i]
            }
            if (shown >= 0 && NR > shown) printf "    ... and %s more\n", grouped(NR - shown)
        }'
}

# The listing, at most 20 entries, from the three lists _untracked_entries
# reads on stdin.
_untracked_listing_render() {
    _untracked_entries | _untracked_listing_format 20
}

# The three lists _untracked_entries reads, for the paths at risk in a
# checkout given one per line, and paths that stay beside the tracked ones
# (deleted anyway, so never inside a collapsed entry). git lists a nested
# repository as one path ending in "/", so the files under each are counted
# here. The tracked paths include those of every initialised submodule, and
# every submodule's own path (_submodule_dirs), so a path at risk inside one
# (_submodule_others) is never collapsed into the submodule or a directory
# above it. Fails when git cannot list the tracked paths or a nested
# repository cannot be read.
_untracked_listing_input() {  # checkout_dir paths [staying_paths]
    local dir="$1" paths="$2" staying="${3:-}" tracked submodules nested="" repo name files
    tracked=$(git -C "$dir" ls-files -z --recurse-submodules | _names_as_lines) || return 1
    submodules=$(_submodule_dirs "$dir" "") || return 1
    [ -z "$submodules" ] || tracked="${tracked:+$tracked$'\n'}$submodules"
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        printf -v name '%b' "$repo"
        # One NUL per file: a path may hold a newline.
        files=$(find "$dir/$name" ! -type d -print0 | env LC_ALL=C tr -dc '\0' | wc -c) || return 1
        nested="$nested${files//[[:space:]]/}"$'\t'"$repo"$'\n'
    done <<< "$(printf '%s\n' "$paths" | env LC_ALL=C grep '/$' || [ $? -eq 1 ])"
    [ -z "$tracked" ] || printf '%s\n' "$tracked"
    [ -z "$staying" ] || printf '%s\n' "$staying"
    printf '\n%s\n' "$nested"
    printf '%s\n' "$paths"
}

# The listing of files a removal of the checkout would destroy, at most 20
# entries, for the paths at risk given one per line.
_untracked_listing() {  # checkout_dir paths
    local input
    input=$(_untracked_listing_input "$1" "$2") || return 1
    printf '%s\n' "$input" | _untracked_listing_render
}

# Print the PID of a live lock on a session that the invoker does not own:
# empty when the lock is absent, names no running process by live_lock_pid's
# rule, or is the invoking conversation's own (session_lock_owned_by_invoker).
# The integrate and retire entries both refuse on a non-empty answer, and
# -features reports it as the lock that would refuse them.
_foreign_live_lock_pid() {  # session_name meta_dir
    local pid
    pid=$(live_lock_pid "$2")
    [ -n "$pid" ] || return 0
    session_lock_owned_by_invoker "$1" "$pid" && return 0
    printf '%s\n' "$pid"
}

# Absolute form of a `git rev-parse` path answer (--git-dir, --git-common-dir).
# git answers relative to the checkout from a main worktree and absolute from
# a linked one; every path built on the answer (the integrate mutex, the temp
# worktree) must resolve the same from both.
_git_path_abs() {  # checkout_dir rev-parse-flag
    local p
    p=$(git -C "$1" rev-parse "$2" 2>/dev/null) || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *) printf '%s\n' "$1/$p" ;;
    esac
}

# The same merge policy setup_merge_attributes (lib/45-migrate.sh:4) gives a
# checkout, written clone-local: merge.ours.driver into the shared config and
# the four attribute lines (_append_merge_attribute_lines) into
# <common>/info/attributes, which every worktree of the repo reads and which
# dirties no tree. The temp worktree checks out whatever .gitattributes the
# base has committed, which may lack these lines; without them tracked-mode
# timeline, narrative and memory archive appends on both sides conflict
# instead of union-merging.
_setup_merge_attributes_clone_local() {  # base_dir common_dir
    git -C "$1" config merge.ours.driver true 2>/dev/null || true
    mkdir -p "$2/info"
    _append_merge_attribute_lines "$2/info/attributes"
}

# Tracked-.cs mode: MEMORY.md merges with merge=ours, so an edit to it on the
# feature is dropped by the merge that follows (only pointers to new targets
# are appended after it); say so first.
_warn_memory_index_changed() {  # base_dir ref
    local mb
    mb=$(git -C "$1" merge-base HEAD "$2" 2>/dev/null || echo "")
    if [ -n "$mb" ] \
        && ! git -C "$1" diff --quiet "$mb" "$2" -- .cs/memory/MEMORY.md 2>/dev/null; then
        warn "MEMORY.md changed on $2; merge=ours keeps the base copy and appends only pointers to targets it lacks. Review: git -C \"$1\" diff $mb $2 -- .cs/memory/MEMORY.md"
    fi
}

# Print the task name of every verified feature worktree of a base, one per
# line. Glob the sessions root then ask git to confirm each candidate — the
# reverse direction would enumerate the main checkout, and for an adopted base
# it would also enumerate the underlying project's own worktrees, which are not
# cs sessions at all. Asking git for the path on both sides is what makes this
# survive a directory whose two spellings differ, exactly as
# _doctor_check_worktrees does.
_worktree_features() {  # base_name
    local base_name="$1"
    local base_dir d name task d_real registered
    base_dir=$(_resolve_session_dir "$base_name")
    [ -d "$base_dir" ] || return 0
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0

    registered=$(git -C "$base_dir" worktree list --porcelain 2>/dev/null || true)

    for d in "$SESSIONS_ROOT/$base_name"@*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        task="${name#*@}"
        [ -n "$task" ] || continue
        d_real=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) \
            || d_real=$(cd -- "$d" 2>/dev/null && pwd -P || echo "$d")
        case "
$registered
" in
            *"
worktree $d_real
"*) printf '%s\n' "$task" ;;
        esac
    done
}

# Print one tab-separated readiness record for a base's feature worktree:
#   task branch ahead merged ff wt_dirty untracked base_dirty lock state
# Every fact is computed by the function the real gate calls, so the answer can
# never disagree with the refusal the merge would produce.
_feature_readiness() {  # base_name task
    local base_name="$1" task="$2"
    local base_dir wt_dir wt_name branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_name="$base_name@$task"
    wt_dir="$SESSIONS_ROOT/$wt_name"
    branch=$(_read_local_state "$wt_dir/.cs/local/state" task_branch)
    [ -n "$branch" ] || branch="cs/$task"

    local ahead=0 merged=0 ff=0 wt_dirty=0 untracked=0 base_dirty=0 lock="none"

    ahead=$(git -C "$base_dir" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)

    # "Already merged" needs the tip STRICTLY behind base HEAD. A fresh
    # worktree's branch sits AT base HEAD, where is-ancestor is also true, so
    # a bare is-ancestor would report untouched work as landed. Same guard as
    # _doctor_check_worktrees.
    if git -C "$base_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null \
        && [ "$(git -C "$base_dir" rev-parse "$branch" 2>/dev/null)" \
             != "$(git -C "$base_dir" rev-parse HEAD 2>/dev/null)" ]; then
        merged=1
    fi

    # A merge fast-forwards when base HEAD is already an ancestor of the
    # branch: `git merge --no-edit` carries no --no-ff, so no merge commit is
    # written and the screen must not promise one.
    if git -C "$base_dir" merge-base --is-ancestor HEAD "$branch" 2>/dev/null; then
        ff=1
    fi

    _tree_is_dirty "$wt_dir" && wt_dirty=1
    local hidden
    hidden=$(_hidden_tracked_edits "$wt_dir") \
        || error "Could not list the index of $wt_dir"
    [ -z "$hidden" ] || wt_dirty=1
    _tree_is_dirty "$base_dir" && base_dirty=1

    # The screen does not read either checkout's .claude/settings.local.json,
    # so it predicts none of the refusals the retire makes over them, each
    # before it removes anything: a file it would add the feature's rules to
    # and cannot read, a link at the feature's file, a feature .claude link
    # cs cannot follow to a directory inside the worktree, a base .claude
    # that links out of the session when a rule would be written through it,
    # and a git that cannot say whether a checkout tracks the file.
    # A locked base vault is the retire's refusal before the records are
    # classified, and every record bound for it would read as at risk, so the
    # records are not classified then.
    local others conflicts="" vault_locked=""
    others=$(_worktree_untracked_at_risk "$wt_dir") \
        || error "Could not list the untracked files in $wt_dir"
    if [ "$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)" = "ignored" ]; then
        vault_locked=$(_locked_vault_link "$base_dir/.cs")
        if [ -z "$vault_locked" ]; then
            conflicts=$(_fuse_conflicts "$wt_dir/.cs" "$base_dir/.cs" "$task") \
                || error "Could not classify the session records in $wt_dir/.cs"
        fi
    fi
    others="$others${others:+${conflicts:+$'\n'}}$conflicts"
    if [ -n "$others" ]; then
        untracked=$(printf '%s\n' "$others" | wc -l | tr -d '[:space:]')
    fi

    # Gate order: base lock, then worktree lock. A lock owned by this invoker
    # is exempt, exactly as the merge gate treats it.
    local lock_session lock_meta
    for lock_session in "$base_name" "$wt_name"; do
        if [ "$lock_session" = "$base_name" ]; then
            lock_meta="$base_dir/.cs"
        else
            lock_meta="$wt_dir/.cs"
        fi
        [ -n "$(_foreign_live_lock_pid "$lock_session" "$lock_meta")" ] || continue
        if [ "$lock_session" = "$base_name" ]; then lock="base"; else lock="worktree"; fi
        break
    done

    # State is the first blocker retire_feature_worktree would hit, in its order.
    local state="ready"
    if [ "$lock" = "worktree" ] && [ -f "$base_dir/.cs/local/retire-staged/$task" ]; then
        state="staged"
    elif [ "$lock" != "none" ]; then
        state="locked"
    elif [ "$wt_dirty" = 1 ]; then
        state="dirty"
    elif [ "$untracked" != 0 ]; then
        state="untracked"
    elif [ -n "$vault_locked" ]; then
        state="vault-locked"
    elif [ "$base_dirty" = 1 ]; then
        state="base-dirty"
    elif [ "$merged" = 1 ]; then
        state="merged"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$task" "$branch" "$ahead" "$merged" "$ff" \
        "$wt_dirty" "$untracked" "$base_dirty" "$lock" "$state"
}

# Resolve a symlinked directory to its real path, portably. BSD readlink gained
# -f only in macOS 12.3; cd+pwd -P follows the link on every platform, and the
# fallback keeps the original path rather than aborting under set -e.
_resolve_symlink_dir() {
    (cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# Resolve a session name to its real directory (adopted sessions are
# symlinks into the project checkout). Prints the resolved path.
_resolve_session_dir() {
    local dir="$SESSIONS_ROOT/$1"
    [ -L "$dir" ] && dir="$(_resolve_symlink_dir "$dir")"
    printf '%s\n' "$dir"
}

# Refuse a base whose HEAD names no commit: a folder cs -adopt ran git init
# in has none until the user makes one, and git would make a feature of it an
# orphan branch, then fail on HEAD when landing it.
_require_base_commit() {  # base_dir base_name
    git -C "$1" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 \
        || error "Session '$2' has no commit yet, so a feature has nothing to branch from or land on. Make a first commit in $1 (cs commits nothing for you), then try again."
}

# Gate worktree creation on the base checkout's tracked state. Runs in the
# main shell so a declined consent can exit cs cleanly (the creator is
# command-substituted, where an exit only leaves the subshell). Clean base
# returns; dirty base asks for informed consent on interactive terminals
# (the feature branches from the last commit and will not include uncommitted
# changes) and refuses everywhere else.
confirm_clean_worktree_base() {
    local base_dir="$1" base_name="$2"
    git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    _require_base_commit "$base_dir" "$base_name"
    _tree_is_dirty "$base_dir" || return 0
    if cs_interactive; then
        printf '\n    %b⚠%b  %s has uncommitted changes; the feature branches from the\n       last commit and will not include them.\n' \
            "$YELLOW" "$NC" "$base_name"
        printf '    Continue?  %b[y/N]%b %b›%b ' "$DIM" "$NC" "$GOLD" "$NC"
        local consent=""
        read -r consent || consent=""
        if [[ ! "$consent" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            exit 0
        fi
    else
        error "Session '$base_name' has uncommitted changes; commit them first (a worktree materializes committed state only)"
    fi
}

# Create a linked git worktree of a base session as a sibling session dir.
# The caller gates dirty base state via confirm_clean_worktree_base. Prints
# the new worktree path.
create_worktree_session() {
    local base_dir="$1" base_name="$2" task="$3"
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    if ! git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1; then
        error "Session '$base_name' has no git repo; worktrees need one"
    fi
    if [ -f "$base_dir/.git" ]; then
        error "Session '$base_name' is itself a worktree; create features from the main checkout"
    fi
    _require_base_commit "$base_dir" "$base_name"
    # The feature lands on the base's branch at /finish; a detached base has
    # none, so refuse now rather than after the work is done.
    git -C "$base_dir" symbolic-ref -q HEAD >/dev/null 2>&1 \
        || error "Session '$base_name' is detached (no branch checked out), so a feature would have no branch to land on. Check out the branch the feature should land on, then try again."
    # Who carries .cs from the feature back to the base: git (tracked) or the
    # record fuse (ignored). Git's answer wins once it tracks .cs. Otherwise a
    # mode the base records decides (adopt and the flat-layout migration
    # record one, since they commit nothing), and only a base with no record
    # is inferred ignored.
    # Decided before the worktree exists, so a refusal leaves nothing behind.
    local mode state_file="$base_dir/.cs/local/state" recorded
    if [ -n "$(git -C "$base_dir" ls-files -- .cs 2>/dev/null)" ]; then
        mode="tracked"
    else
        recorded=$(_read_local_state "$state_file" cs_mode)
        case "$recorded" in
            ""|ignored) mode="ignored" ;;
            tracked) error "Session '$base_name' expects git to carry .cs (cs_mode: tracked in $state_file), but git tracks nothing under .cs there. Commit it first (git add .cs .gitignore .gitattributes, then git commit, in $base_dir), or set that line to 'cs_mode: ignored' to keep .cs out of git, which features then hide through .git/info/exclude." ;;
            *) error "Session '$base_name' names cs_mode '$recorded' in $state_file; cs knows tracked and ignored. Fix that line, then create the feature again." ;;
        esac
    fi
    # Dirty-state gating happens in the caller (confirm_clean_worktree_base):
    # this function runs command-substituted, where an exit cannot stop cs.
    local untracked
    untracked=$(git -C "$base_dir" ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
    if [ -n "$untracked" ]; then
        warn "Untracked files will not appear in the worktree:" >&2
        printf '%s\n' "$untracked" >&2
    fi

    if git -C "$base_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        # The branch's own tip, not the base's HEAD, is where the feature
        # starts; say so, with how far behind the base that tip sits.
        local behind
        behind=$(git -C "$base_dir" rev-list --count "$branch..HEAD" 2>/dev/null) || behind="?"
        warn "Branch $branch already exists; the feature starts from its tip, $behind commit$([ "$behind" = 1 ] || printf s) behind $base_name" >&2
        git -C "$base_dir" worktree add "$wt_dir" "$branch" >/dev/null \
            || error "git worktree add failed (is branch '$branch' checked out in another worktree?)"
    else
        git -C "$base_dir" worktree add -b "$branch" "$wt_dir" >/dev/null \
            || error "git worktree add failed"
    fi
    # The checkout can carry a committed link or per-actor state from the
    # base's history; refuse before the state writes below go through it.
    cs_assert_local_untracked "$wt_dir"

    if [ "$mode" = "ignored" ]; then
        bootstrap_worktree_meta "$wt_dir" "$base_name" "$task" "$base_dir"
    fi

    # The protocol file is normally gitignored, so no worktree inherits it
    # through git in either mode; write this worktree's own copy. The FILE
    # only — never touch a .gitignore here (ignored-mode worktrees check out
    # project repos whose .gitignore is theirs). Guarded: a repo that
    # (against CC convention) TRACKS CLAUDE.local.md checks its own copy
    # into the worktree; only overwrite when absent or already cs's own.
    if [ ! -f "$wt_dir/CLAUDE.local.md" ] \
        || grep -q 'cs:session-protocol' "$wt_dir/CLAUDE.local.md"; then
        write_session_claude_md "$wt_dir"
    fi

    # Cover the protocol file via the clone-local info/exclude in BOTH
    # modes. In ignored mode the checkout's .gitignore belongs to the
    # project and is never touched. In tracked mode the file is normally
    # covered by the base's own .gitignore entry — but a base committed
    # before the CLAUDE.local.md backfill (and never relaunched since)
    # checks out a .gitignore missing it, which would otherwise leave the
    # file untracked and block retirement's preflight. The exclude
    # entry is clone-local and harmless alongside a .gitignore entry (never
    # tracked, never dirties the task branch; shared with the base checkout
    # through the common git dir).
    local exclude
    exclude=$( (cd -- "$wt_dir" && git rev-parse --git-path info/exclude) 2>/dev/null || echo "" )
    # A worktree's git-path resolves to the common git dir, which git reports
    # as an absolute path. Reading that as relative would prepend $wt_dir,
    # writing the exclude entry to a nonsense path and leaving the protocol file
    # untracked, which then blocks retirement.
    case "$exclude" in
        "") : ;;
        /*) : ;;
        *) exclude="$wt_dir/$exclude" ;;
    esac
    if [ -n "$exclude" ]; then
        mkdir -p "${exclude%/*}" 2>/dev/null || true
        if ! grep -qF 'CLAUDE.local.md' "$exclude" 2>/dev/null; then
            echo 'CLAUDE.local.md' >> "$exclude"
        fi
        if ! grep -qF '.claude/settings.local.json' "$exclude" 2>/dev/null; then
            echo '.claude/settings.local.json' >> "$exclude"
        fi
        # Ignored mode means .cs is not TRACKED — it does not mean the project
        # ignores it. Where the project's .gitignore never named .cs/, the
        # skeleton bootstrap_worktree_meta just wrote shows up as untracked in
        # every git status the user runs here. Tracked mode must not get this
        # entry: there .cs belongs to the checkout.
        if [ "$mode" = "ignored" ] && ! grep -qF '.cs/' "$exclude" 2>/dev/null; then
            echo '.cs/' >> "$exclude"
        fi
    fi

    # Creating the feature is creating a session, so this makes its .cs: a
    # tracked-mode checkout can lack one, when the branch is older than the
    # base's .cs or HEAD does not hold a .cs the user has only staged. The
    # state writes below make only the last level.
    mkdir -p "$wt_dir/.cs/local" || error "could not create $wt_dir/.cs/local"
    local state="$wt_dir/.cs/local/state"
    _set_local_state "$state" claude_session_id "$(_alloc_uuid)"
    _set_local_state "$state" claude_session_color "$(_alloc_random_color)"
    _set_local_state "$state" task_branch "$branch"
    _set_local_state "$state" cs_mode "$mode"
    _set_local_state "$state" cs_base "$base_name"

    setup_auto_memory "$wt_dir"

    # A feature worktree is a full cs session holding the same narrative, plans
    # and machine-local state as its base, so it gets the same privacy. cs
    # created this directory, so unlike an adopted session the ROOT is cs's to
    # set too. Kept here rather than left to migrate_session, which the worktree
    # open path deliberately never calls.
    _harden_session_meta "$wt_dir"
    chmod 700 "$wt_dir" 2>/dev/null || true

    echo "$wt_dir"
}

# The /finish progress record: one JSON object, replaced whole at each step of
# an integrate or a retire, that the cs mod reads to toast a start and an
# outcome and to draw a band while a gate runs (docs/session-layout.md). It
# sits with the base's other cs files: behind .cs/private in an encrypted
# session, in .cs/local otherwise, and nowhere while the vault is locked.
# Advisory only: a record that cannot be written costs one warning on stderr
# and the run goes on unrecorded, since landing correctly matters more than
# saying so. Each run has its own id; pid is this cs process, so a reader can
# tell a step a killed run left behind from one still running. Globals,
# because the EXIT handler that records a refusal runs after the locals are
# gone.
_finish_progress_begin() {  # base_dir task
    _FINISH_PROGRESS="" _FINISH_ID="$$-$(date +%s)" _FINISH_TASK="$2"
    _FINISH_SHA="" _FINISH_GATE_STARTED="" _FINISH_OUTCOME=""
    local dir
    if ! dir=$(cs_private_dir "$1/.cs"); then
        warn "cs: /finish progress not recorded: .cs/private $(cs_private_state "$1/.cs")" >&2
        return 0
    fi
    if ! CS_WRITE_QUIET=1 cs_mkdir_inside "$dir"; then
        warn "cs: /finish progress not recorded: could not create $dir" >&2
        return 0
    fi
    _FINISH_PROGRESS="$dir/finish-progress.json"
    trap '_finish_progress_exit "$?"' EXIT
}

# Replace the record with this run at <step>; an outcome (landed, refused,
# retired) may carry one more field, the landed commit or the refusal's reason.
_finish_progress_write() {  # step [key value]
    [ -n "${_FINISH_PROGRESS:-}" ] || return 0
    local step="$1" key="${2:-}" value="${3:-}"
    case "$step" in landed|refused|retired) _FINISH_OUTCOME="$step" ;; esac
    if ! cs_write_atomic "$_FINISH_PROGRESS" jq -nc \
            --arg id "$_FINISH_ID" --argjson pid "$$" --arg task "$_FINISH_TASK" \
            --arg sha "$_FINISH_SHA" --arg step "$step" --argjson ts "$(date +%s)" \
            --arg gate_started "$_FINISH_GATE_STARTED" --arg key "$key" --arg value "$value" \
            '{id: $id, pid: $pid, task: $task, sha: $sha, step: $step, ts: $ts}
             + (if $gate_started == "" then {} else {gate_started: ($gate_started | tonumber)} end)
             + (if $key == "" then {} else {($key): $value} end)' 2>/dev/null; then
        warn "cs: /finish progress not recorded: could not write $_FINISH_PROGRESS" >&2
        _FINISH_PROGRESS=""
    fi
    return 0
}

# The EXIT handler: a run that ends in failure before it wrote an outcome was
# refused, and the reason is the first line of the error that ended it. Never
# fails, so a handler chained after it still runs and the exit status stands.
_finish_progress_exit() {  # exit status
    if [ "$1" = 0 ] || [ -z "${_FINISH_PROGRESS:-}" ] || [ -n "${_FINISH_OUTCOME:-}" ]; then
        return 0
    fi
    local reason="${_CS_ERROR_MESSAGE:-}"
    reason="${reason%%$'\n'*}"
    if [ -z "$reason" ]; then
        case "$1" in 130|143) reason="interrupted" ;; *) reason="cs exited $1" ;; esac
    fi
    _finish_progress_write refused reason "$reason" || true
    return 0
}

# Move the worktree's ignored files that are not regenerable to the system
# trash, so retiring it deletes nothing git keeps no copy of; files under a
# regenerable directory (CS_REGENERABLE_DIRS) go with the worktree. Leaves
# what it moved in _RETIRE_TRASHED_COUNT and _RETIRE_TRASHED_LINES (one line
# per entry, by absolute path) for _retire_trashed_note. Refuses, having
# removed nothing, when no trash command is installed or its first call
# fails; when a later call fails, refuses naming what the earlier calls
# moved.
_retire_trash_ignored_work() {  # wt_dir task
    local wt_dir="$1" task="$2" ignored trash_paths regenerable input entries listing count them=them nl=$'\n'
    ignored=$(_worktree_others "$wt_dir" --ignored) \
        || error "Could not list the ignored files in $wt_dir; nothing was removed"
    [ -n "$ignored" ] || return 0
    trash_paths=$(printf '%s\n' "$ignored" | _regenerable_filter other)
    [ -n "$trash_paths" ] || return 0
    regenerable=$(printf '%s\n' "$ignored" | _regenerable_filter regenerable)
    input=$(_untracked_listing_input "$wt_dir" "$trash_paths" "$regenerable") \
        && entries=$(printf '%s\n' "$input" | _untracked_entries) \
        || error "Could not count the ignored files in $wt_dir; nothing was removed"
    listing=$(printf '%s\n' "$entries" | _untracked_listing_format 20)
    count="${listing%%"$nl"*}"
    [ "$count" != "1 file" ] || them=it
    local -a trash_cmd=() targets=()
    local word entry name
    while IFS= read -r word; do trash_cmd+=("$word"); done <<< "$(_system_trash_command)"
    [ -n "${trash_cmd[0]:-}" ] \
        || error "Worktree has ${count% *} ignored ${count#* } that retiring moves to the system trash, but neither trash nor gio is installed, so nothing was removed. Move or delete $them, then run /finish $task here again:
${listing#*"$nl"}"
    # An entry is a line of _names_as_lines: the trash command gets the name
    # it stands for, as it is on disk.
    while IFS= read -r entry; do
        entry="${entry#*$'\t'}"
        printf -v name '%b' "${entry%/}"
        targets+=("$wt_dir/$name")
    done <<< "$entries"
    # The trash command gets the entries over as many calls as keep each
    # within CS_TRASH_CALL_BYTES. A call that fails ends the retire. When it
    # is the first, nothing is known to have moved; when it is a later one,
    # the entries of the calls before it are in the trash, and the refusal
    # lists them after the ones still in the worktree.
    local trash_err sizes size first=0
    sizes=$(printf '%s\n' "$entries" | _retire_trash_call_sizes "$wt_dir/") \
        || error "Could not size the calls of ${trash_cmd[0]} for $wt_dir; nothing was removed"
    while IFS= read -r size; do
        if ! trash_err=$("${trash_cmd[@]}" "${targets[@]:first:size}" 2>&1 >/dev/null); then
            [ "$first" -gt 0 ] \
                || error "Could not move ${count% *} ignored ${count#* } to the system trash, so nothing was removed; anything the trash command did move is in the trash. Move or delete $them, then run /finish $task here again:
${listing#*"$nl"}
${trash_cmd[0]}: ${trash_err:-exited with an error}"
            _retire_trashed_set "$wt_dir" "$(printf '%s\n' "$entries" | awk -v moved="$first" 'NR <= moved')"
            listing=$(printf '%s\n' "$entries" | tail -n "+$((first + 1))" | _untracked_listing_format 20)
            count="${listing%%"$nl"*}"
            them=them
            [ "$count" != "1 file" ] || them=it
            error "Could not move ${count% *} ignored ${count#* } to the system trash, so the worktree was not removed; anything the trash command did move is in the trash. Move or delete $them, then run /finish $task here again:
${listing#*"$nl"}
${trash_cmd[0]}: ${trash_err:-exited with an error}
$(_retire_trashed_note " before this failed")"
        fi
        first=$((first + size))
    done <<< "$sizes"
    _retire_trashed_set "$wt_dir" "$entries"
}

# How many of the entries on stdin (_untracked_entries) each call of the
# trash command gets, one number per line: as many as keep the call's paths,
# each under the directory given and counted with one byte to end it, within
# CS_TRASH_CALL_BYTES, and never fewer than one.
_retire_trash_call_sizes() {  # directory
    env LC_ALL=C CS_TRASH_DIRECTORY="$1" awk -v budget="$CS_TRASH_CALL_BYTES" '
        {
            bytes = length(ENVIRON["CS_TRASH_DIRECTORY"]) + length($0) - index($0, "\t") + 1
            if (held > 0 && sum + bytes > budget) { print held; held = 0; sum = 0 }
            held++
            sum += bytes
        }
        END { if (held > 0) print held }'
}

# Record the entries given (_untracked_entries) as moved to the system trash
# from the worktree, for _retire_trashed_note.
_retire_trashed_set() {  # wt_dir entries
    local listing nl=$'\n'
    listing=$(printf '%s\n' "$2" | _untracked_listing_format all "$1/")
    _RETIRE_TRASHED_COUNT="${listing%%"$nl"*}"
    _RETIRE_TRASHED_LINES="${listing#*"$nl"}"
}

# What _retire_trash_ignored_work moved to the system trash, as a heading
# ending in $1 and one line per entry; nothing when it moved nothing.
_retire_trashed_note() {  # heading_end
    [ -n "${_RETIRE_TRASHED_COUNT:-}" ] || return 0
    printf 'Moved %s ignored %s to the system trash%s:\n%s\n' \
        "${_RETIRE_TRASHED_COUNT% *}" "${_RETIRE_TRASHED_COUNT#* }" "$1" "$_RETIRE_TRASHED_LINES"
}

# Retire an integrated feature worktree: fuse its session records into the
# base (ignored mode), remove the worktree and delete its branch. Backs the
# unadvertised `cs <base> -retire-feature <task> <sha> [--force]` that
# skills/finish/scripts/finish.sh drives after an integrate. It never merges:
# <sha> is the commit /finish landed and must already be reachable from the
# base, and the branch tip must be too, so nothing the base lacks is ever
# discarded. --force is the squash-merged-PR path — the skill passes it only
# on GitHub's evidence that the PR merged, since the branch is then never an
# ancestor — and every other refusal still applies. Every refusal names what
# the user has to do next, in their own words; the skill prints them verbatim.
retire_feature_worktree() {  # base_name task sha [--force] [--staged]
    local usage="Usage: cs <base> -retire-feature <task> <sha> [--force] [--staged]"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3" force="" staged=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            --staged) staged=1; shift ;;
            *) error "$usage" ;;
        esac
    done
    local base_dir
    base_dir=$(_resolve_session_dir "$base_name")
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    _finish_progress_begin "$base_dir" "$task"
    _require_base_commit "$base_dir" "$base_name"

    local wt_name="$base_name@$task"
    if [ "${CLAUDE_SESSION_NAME:-}" = "$wt_name" ]; then
        error "This is the '$wt_name' conversation itself, and a worktree can't remove the directory it is running in. Close this session, then run /finish $task in '$base_name'."
    fi

    local commit
    commit=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    sha="$commit"
    _FINISH_SHA="$sha"
    local tip
    tip=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null) || error "Not a git checkout: $wt_dir"
    # Without --force the captured commit must be in the base. With it (a
    # squash-merged PR, on GitHub's evidence) that check is skipped, but the
    # branch tip must still be at or behind the captured commit either way:
    # a commit made after the capture is work no landing carried, and
    # deleting the branch would lose it.
    if [ -z "$force" ]; then
        git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
            || error "$sha is not integrated into $base_name; run /finish $task before retiring"
    fi
    if ! git -C "$base_dir" merge-base --is-ancestor "$tip" "$sha" 2>/dev/null \
        && { [ -n "$force" ] || ! git -C "$base_dir" merge-base --is-ancestor "$tip" HEAD 2>/dev/null; }; then
        local n_after
        n_after=$(git -C "$wt_dir" rev-list --count "$sha..HEAD" 2>/dev/null || echo "?")
        error "$n_after commit(s) on $branch after $sha are not integrated; run /finish $task again before retiring"
    fi

    # --staged runs a stage this base wrote earlier, from its Stop hook, which
    # is no descendant of the base's claude once detached: the stage, written
    # only after the base-lock check below passed, stands in for that
    # ancestry. It must exist and record this very decision.
    local pid stage="$base_dir/.cs/local/retire-staged/$task"
    if [ -n "$staged" ]; then
        local force_word=0
        [ -z "$force" ] || force_word=1
        [ "$(cat "$stage" 2>/dev/null)" = "sha: $sha
force: $force_word" ] || error "No stage at $stage records retiring $task at $sha with force=$force_word; run /finish $task to stage it"
    else
        pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs")
        if [ -n "$pid" ]; then
            error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"
        fi
    fi
    pid=$(_foreign_live_lock_pid "$wt_name" "$wt_dir/.cs")
    if [ -n "$pid" ]; then
        # A directory can't be removed from under a running Claude, so the
        # decision this retire already made (the commit, --force or not) is
        # staged in the base, and the base's Stop hook runs this entry again
        # once that conversation's lock is gone. Every refusal below runs
        # then as it would now.
        _write_retire_stage "$stage" "$sha" "$force" \
            || error "The feature is landed, but its worktree is still here: the '$wt_name' conversation is open in it (PID $pid), and cs could not stage its removal at $stage. Close that session yourself (/exit there), then run /finish $task here again and it will be removed."
        printf "staged %s %s: the '%s' conversation is open in its worktree (PID %s); the worktree and branch are removed from this session once that conversation closes\n" \
            "$task" "$sha" "$wt_name" "$pid"
        return 0
    fi

    # git worktree remove --force recurses into a mount, so a volume mounted
    # inside the worktree would lose what it holds.
    local mounted
    mounted=$(_volume_mounted_under "$wt_dir") \
        || error "cs could not read the mount table, so it cannot tell whether a volume is mounted inside $wt_dir; refusing to remove the worktree."
    [ -z "$mounted" ] \
        || error "The feature is landed, but its worktree has a volume mounted inside it at $mounted, and removing the worktree would delete what the volume holds. Unmount it, then run /finish $task here again."

    if _tree_is_dirty "$wt_dir"; then
        error "Worktree has uncommitted changes; commit them in $wt_dir first (cs never commits for you)"
    fi
    local hidden
    hidden=$(_hidden_tracked_edits "$wt_dir") \
        || error "Could not list the index of $wt_dir; nothing was removed"
    if [ -n "$hidden" ]; then
        error "Worktree has edits git diff does not show (skip-worktree or assume-unchanged), which removal would destroy; commit them, or undo them and clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged), first:
$hidden"
    fi
    # The mode says who carries .cs into the base: git (tracked) or the record
    # fuse below (ignored). Without one, nothing under .cs is known to survive.
    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    case "$mode" in
        tracked|ignored) ;;
        *) error "$wt_dir/.cs/local/state names no cs_mode, so cs cannot tell whether git or the record fuse carries $wt_dir/.cs; nothing was removed. Add the line 'cs_mode: tracked' if git tracks .cs in $base_name, else 'cs_mode: ignored', then run /finish $task again." ;;
    esac
    local wt_untracked
    wt_untracked=$(_worktree_untracked_at_risk "$wt_dir") \
        || error "Could not list the untracked files in $wt_dir; nothing was removed"
    if [ -n "$wt_untracked" ]; then
        local wt_listing wt_count wt_them=them nl=$'\n'
        wt_listing=$(_untracked_listing "$wt_dir" "$wt_untracked") \
            || error "Could not count the untracked files in $wt_dir; nothing was removed"
        wt_count="${wt_listing%%"$nl"*}"
        [ "$wt_count" != "1 file" ] || wt_them=it
        error "Worktree has ${wt_count% *} untracked ${wt_count#* } that removal would destroy; commit or remove $wt_them first:
${wt_listing#*"$nl"}"
    fi
    if [ "$mode" = "ignored" ]; then
        # A locked vault leaves its links dangling, and every record bound
        # for one would read as a conflict to merge or delete by hand; the
        # vault is named first, and mounting it is the remedy.
        local locked
        locked=$(_locked_vault_link "$base_dir/.cs")
        [ -z "$locked" ] \
            || error "cannot fuse the worktree's records: $base_dir/.cs/$locked is locked. Mount it, then retry."
        local conflicts entry merge="" blocked="" refusal="" removed="Nothing was removed. "
        conflicts=$(_fuse_conflicts "$wt_dir/.cs" "$base_dir/.cs" "$task") \
            || error "Could not classify the session records in $wt_dir/.cs; nothing was removed"
        while IFS= read -r entry; do
            case "$entry" in
                "conflict "*) merge="$merge${merge:+$'\n'}${entry#conflict }" ;;
                "blocked "*) blocked="$blocked${blocked:+$'\n'}${entry#blocked }" ;;
            esac
        done <<< "$conflicts"
        if [ -n "$merge" ]; then
            refusal="The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt_dir/.cs, then run /finish $task again:
$merge"
            removed=""
        fi
        # The feature's own README and summary go under .cs/features/<task>/,
        # never into the base's .cs itself, so they are named under that path.
        # The dispatch refuses a task name cs does not accept before the
        # retire, so here the path is what blocks them.
        if [ -n "$blocked" ]; then
            refusal="$refusal${refusal:+$'\n'}The feature's own README and summary go to $base_dir/.cs/features/$task/, and cs cannot make that directory: the base holds a file, a dangling link or a link out of the session on the way to it. ${removed}Move that aside, or delete each from $wt_dir/.cs, then run /finish $task again:
$blocked"
        fi
        [ -z "$refusal" ] || error "$refusal"
    fi
    # The base's own .cs/ bookkeeping is exempt: in tracked mode the integrate
    # that just landed this feature wrote a timeline event there, and removing
    # a worktree touches no base file, so that dirt is no reason to refuse.
    if ! git -C "$base_dir" diff --quiet -- . ':(exclude).cs' 2>/dev/null \
        || ! git -C "$base_dir" diff --cached --quiet -- . ':(exclude).cs' 2>/dev/null; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi

    # Ignored-mode records are fused only once the worktree is gone: set them
    # aside, remove, then fuse from the copy, so a removal that fails (a
    # locked worktree, say) leaves the base's records untouched and puts the
    # worktree's own back, and the retry fuses exactly once.
    # The staging directory sits beside the worktree, on its filesystem, so
    # both moves are renames: nothing is half-copied on a failure.
    # A fuse that refuses after the removal would strand the records in the
    # staging directory, so its one refusal is asked before anything moves.
    # Asked whether or not the worktree has a log: a locked vault takes the
    # base's .cs/memory with it, which the fuse writes for any narrative.
    # Claude Code writes the permission rules set in the feature (allow, deny,
    # ask) to its own .claude/settings.local.json, which git does not carry.
    # They go into the base's before the removal; a removal that then fails
    # leaves them there, and the retry's union changes nothing.
    # The files are read only when the rules are carried: one the retire
    # leaves alone is no reason to refuse, whatever it holds.
    local settings carried=0
    _permission_rules_carried "$wt_dir" "$base_dir" || carried=$?
    if [ "$carried" = 3 ]; then
        [ ! -L "$wt_dir/.claude/settings.local.json" ] \
            || error "$wt_dir/.claude/settings.local.json is a link, and cs reads the feature's permission rules only from a file of its own. Nothing was removed. Put the rules in a file there, or delete the link, then run /finish $task again."
        error "$wt_dir/.claude is a link cs cannot follow to a directory inside $wt_dir, and cs reads the feature's permission rules only from a file inside it. Nothing was removed. Replace the link with a directory of the feature's own, or remove it, and commit that, then run /finish $task again."
    fi
    if [ "$carried" = 2 ]; then
        local link missing
        link=$(_settings_link "$base_dir")
        _settings_rules_readable "$wt_dir/.claude/settings.local.json" \
            || error "$wt_dir/.claude/settings.local.json is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot list the feature's permission rules that $link, a link, does not take. Nothing was removed. Fix it, then run /finish $task again."
        missing=$(_settings_rules_missing "$base_dir/.claude/settings.local.json" "$wt_dir/.claude/settings.local.json") \
            || error "Could not list the feature's permission rules that $link, a link, does not take; nothing was removed"
        [ -z "$missing" ] \
            || info "$link is a link, and cs writes nothing through it. Add by hand the feature's permission rules it lacks that the base needs:
$missing"
    elif [ "$carried" = 0 ]; then
        for settings in "$wt_dir/.claude/settings.local.json" "$base_dir/.claude/settings.local.json"; do
            _settings_rules_readable "$settings" \
                || error "$settings is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot add the feature's permission rules to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish $task again."
        done
        _carry_permission_rules "$wt_dir" "$base_dir" \
            || error "Could not add the feature's permission rules to $base_dir/.claude/settings.local.json; nothing was removed"
    fi

    local aside=""
    if [ "$mode" = "ignored" ] && ! cs_private_dir "$base_dir/.cs" >/dev/null; then
        # A link here is a vault locked since the vault-link check above;
        # anything else is a .cs/private that is no directory at all, which
        # no mount fixes.
        [ -L "$base_dir/.cs/private" ] \
            || error "cannot fuse the worktree's records: $base_dir/.cs/private is not a directory. Nothing was removed. Move it out of $base_dir/.cs, then run /finish $task again."
        error "cannot fuse the worktree's records: $base_dir/.cs/private is locked. Mount it, then retry."
    fi
    # The removal below runs under the feature's openers' mutex, from the
    # first file it moves to the worktree's end: an open that began after the
    # lock check above would otherwise take session.lock in the middle of it
    # and lose the directory from under its claude. Taken here, the opener
    # waits at the mutex and then finds no worktree. The lock is read once
    # more under it, since a conversation can have reopened meanwhile.
    _cs_lock "$wt_dir/.cs/session.mutex.lock" \
        || error "Could not take the openers' mutex of $wt_dir (another cs is opening or closing it); nothing was removed. Run /finish $task again."
    pid=$(live_lock_pid "$wt_dir/.cs")
    if [ -n "$pid" ]; then
        _cs_unlock "$wt_dir/.cs/session.mutex.lock"
        _write_retire_stage "$stage" "$sha" "$force" \
            || error "The '$wt_name' conversation reopened its worktree (PID $pid) before the removal, and cs could not stage it again at $stage; nothing was removed. Run /finish $task here again once it closes."
        printf "staged %s %s: the '%s' conversation reopened its worktree (PID %s) before the removal; the worktree and branch are removed from this session once that conversation closes\n" \
            "$task" "$sha" "$wt_name" "$pid"
        return 0
    fi
    _retire_trash_ignored_work "$wt_dir" "$task"
    local trashed nl=$'\n'
    trashed=$(_retire_trashed_note " before this failed")
    if [ "$mode" = "ignored" ]; then
        aside="$SESSIONS_ROOT/.retire-$wt_name.$$"
        mkdir "$aside" 2>/dev/null || error "Could not create $aside to set aside $wt_dir/.cs for the record fuse${trashed:+$nl$trashed}"
        mv "$wt_dir/.cs" "$aside/cs" || { rmdir "$aside" 2>/dev/null; error "Could not set aside $wt_dir/.cs for the record fuse${trashed:+$nl$trashed}"; }
    fi
    local remove_err
    if ! remove_err=$(git -C "$base_dir" worktree remove --force "$wt_dir" 2>&1); then
        if [ -n "$aside" ]; then
            if mv "$aside/cs" "$wt_dir/.cs"; then
                rmdir "$aside" 2>/dev/null
            else
                error "git worktree remove failed for $wt_dir, and its session records could not be put back: they are at $aside/cs (move that directory to $wt_dir/.cs by hand)
$remove_err${trashed:+$nl$trashed}"
            fi
        fi
        error "git worktree remove failed for $wt_dir; nothing was fused or deleted
$remove_err${trashed:+$nl$trashed}"
    fi
    _cs_unlock "$wt_dir/.cs/session.mutex.lock"
    if [ -n "$aside" ]; then
        ( fuse_session_records "$aside/cs" "$base_dir/.cs" "$task" ) \
            || error "The worktree $wt_dir is removed, but its session records could not be fused into $base_dir/.cs: they are at $aside/cs. Fuse what is missing by hand, then delete that directory.${trashed:+$nl$trashed}"
        rm -rf "$aside"
    fi
    if [ -n "$force" ]; then
        git -C "$base_dir" branch -D "$branch" >/dev/null 2>&1 \
            || warn "Branch $branch was not deleted"
    else
        git -C "$base_dir" branch -d "$branch" >/dev/null 2>&1 \
            || warn "Branch $branch was not deleted (not fully merged?)"
    fi
    _spawn_discard_seeds "$wt_name"

    _append_record "$base_dir/.cs/timeline.jsonl" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "worktree-retired" \
           --arg task "$task" \
        '{ts: $ts, event: $event, task: $task}'
    _finish_progress_write retired
    _retire_trashed_note ""
    # A staged run leaves the stage for the base's Stop hook, which reports
    # the outcome and drops it; a direct retire has no hook behind it.
    [ -n "$staged" ] || rm -f "$stage"
    printf 'retired %s %s\n' "$task" "$sha"
}

# Record a retire the base's Stop hook finishes once the feature conversation
# closes: the captured commit and whether --force applied. Backs the stage
# retire_feature_worktree writes while that conversation holds the worktree.
_write_retire_stage() {  # stage_path sha force
    local force=0
    [ -z "$3" ] || force=1
    cs_mkdir_inside "${1%/*}" || return 1
    cs_write_atomic "$1" printf 'sha: %s\nforce: %s\n' "$2" "$force"
}

# The first of a base's vault links (CS_VAULT_LINKS) that dangles, the vault
# it leads into locked, or nothing. private is asked first, so a vault locked
# whole is named by it.
_locked_vault_link() {  # base_meta
    local sub
    for sub in private $CS_VAULT_LINKS; do
        if [ -L "$1/$sub" ] && [ ! -d "$1/$sub" ]; then
            printf '%s\n' "$sub"
            return 0
        fi
    done
}

# Whether _settings_rules_union can read a Claude Code settings file: a
# missing or zero-byte one reads as {}; any other must hold exactly one JSON
# value, an object whose permissions, when present, is an object and whose
# permissions.allow, deny and ask, each when present, are lists. A null is
# present, not absent: the union reads only the first document and takes a
# null for none.
_settings_rules_readable() {  # file
    [ -s "$1" ] || return 0
    jq -s -e 'length == 1 and (.[0] | type == "object"
        and ((has("permissions") | not) or (.permissions | type == "object" and (. as $p
            | all("allow", "deny", "ask"; . as $k | ($p | has($k) | not) or ($p[$k] | type == "array"))))))' "$1" >/dev/null 2>&1
}

# A Claude Code settings file's JSON, or {} for a missing or zero-byte one.
_settings_json_or_empty() {  # file
    if [ -s "$1" ]; then cat "$1"; else printf '{}\n'; fi
}

# The base's settings with each entry of the feature's permissions.allow,
# deny and ask that the base's same list lacks appended after the base's own,
# in the feature's order, once. A list the feature does not add to is left as
# it is, absent or not; every other key of both files is too.
_settings_rules_union() {  # base_settings feature_settings
    _settings_json_or_empty "$1" | jq --slurpfile f "$2" '
        reduce ("allow", "deny", "ask") as $k (.;
            ($f[0].permissions[$k] // []) as $add
            | if $add == [] then . else
                .permissions[$k] = reduce $add[] as $x ((.permissions[$k] // []);
                    if any(.[]; . == $x) then . else . + [$x] end)
              end)'
}

# The rules _settings_rules_union would add to <base_settings> from
# <feature_settings>, one per line as "  <list>: <rule as JSON>", in the
# union's order. A base file _settings_rules_readable refuses holds no rule cs
# can read, so then every rule of the feature's is listed.
_settings_rules_missing() {  # base_settings feature_settings
    local base="$1"
    _settings_rules_readable "$base" || base=/dev/null
    _settings_json_or_empty "$base" | jq -r --slurpfile f "$2" '
        . as $b | ("allow", "deny", "ask") as $k
        | ($b.permissions[$k] // []) as $have
        | (reduce ($f[0].permissions[$k] // [])[] as $x ($have;
              if any(.[]; . == $x) then . else . + [$x] end)) as $all
        | $all[($have | length):][] | "  \($k): \(tojson)"'
}

# How many permission rules a settings file holds, allow, deny and ask
# together, read from stdin.
_settings_rules_count() {
    jq '[(.permissions // {}) | .allow, .deny, .ask | length] | add'
}

# Whether the index of the checkout at <dir> holds .claude/settings.local.json
# in any letter case: a checkout on a volume that folds case puts a tracked
# .claude/Settings.local.json at the path cs reads, as cs_tracked_files_notice
# finds for .cs. A git that cannot answer has not said the file is untracked:
# the retire refuses then, with git's own error, before anything is removed.
# <claude_dir> is the directory a linked .claude leads to, relative to the
# checkout and empty for the checkout itself: git lists the file there, and
# none behind the link.
_settings_tracked() {  # dir [claude_dir]
    local listed why at="${2-.claude}" spec
    spec=":(icase,literal)${at:+$at/}settings.local.json"
    if listed=$(_cs_git_at "$1" ls-files -- "$spec" 2>/dev/null); then
        [ -n "$listed" ]
        return
    fi
    why=$(_cs_git_error_at "$1" ls-files -- "$spec")
    error "cs could not ask git whether it tracks $1/.claude/settings.local.json: $(_cs_git_complaint "$why"). Nothing was removed."
}

# Whether the retire adds the feature's permission rules to the base's
# settings.local.json: the feature has a file, and neither checkout tracks
# one (git carried it with the integrate, or owns the base's copy since, and
# a union would bring back a rule the base dropped or never took). Returns 2
# for a link at the base's path, wherever it points: the link is the user's
# way of sharing the file, and cs writes nothing through it; the retire lists
# the rules the base lacks instead. The same for a link at the base's .claude
# that stays inside the session: git sees no file behind a linked directory,
# tracked or not, so it is a way of sharing the file git cannot answer for.
# One that leads out of the session is left to the union: its write
# (cs_mkdir_inside) refuses it, and a retire with no rule to add writes
# nothing and goes through. A dangling one whose target has no directory to
# resolve reads as staying inside. Returns 3 for a link at the feature's
# path, leading anywhere or nowhere: cs reads the feature's rules only from a
# file of its own, and the retire refuses it. Returns 3 as well for a link at
# the feature's .claude that cs cannot follow to a directory inside the
# worktree: it leads out, or through more links than _cs_write_target
# follows. One cs can follow is read where it leads: a file git tracks there
# is git's to carry, like one tracked at the feature's path, and any other is
# the feature's own.
_permission_rules_carried() {  # wt_dir base_dir
    local dir root
    [ -s "$1/.claude/settings.local.json" ] || [ -L "$1/.claude/settings.local.json" ] || return 1
    ! _settings_tracked "$1" || return 1
    ! _settings_tracked "$2" || return 1
    [ ! -L "$1/.claude/settings.local.json" ] || return 3
    if [ -L "$1/.claude" ]; then
        dir=$(_cs_write_target "$1/.claude") && root=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 3
        case "$dir/" in "$root"/*) ;; *) return 3 ;; esac
        dir="${dir#"$root"}"
        ! _settings_tracked "$1" "${dir#/}" || return 1
    fi
    [ ! -L "$2/.claude/settings.local.json" ] || return 2
    if [ -L "$2/.claude" ] \
        && ! _cs_refuses_write cs_mkdir_inside "$2/.claude" "$2/.claude" 2>/dev/null; then
        return 2
    fi
}

# The link _permission_rules_carried returned 2 for: the base's
# settings.local.json, or else its .claude.
_settings_link() {  # base_dir
    if [ -L "$1/.claude/settings.local.json" ]; then
        printf '%s\n' "$1/.claude/settings.local.json"
    else
        printf '%s\n' "$1/.claude"
    fi
}

# Add the feature's permission rules to the base's settings.local.json
# (_settings_rules_union), creating it when the base has none, for a retire
# _permission_rules_carried says carries them. Writes nothing when the base
# already holds every rule.
_carry_permission_rules() {  # wt_dir base_dir
    local feat="$1/.claude/settings.local.json" base="$2/.claude/settings.local.json" was now
    was=$(_settings_json_or_empty "$base" | _settings_rules_count) || return 1
    now=$(_settings_rules_union "$base" "$feat" | _settings_rules_count) || return 1
    [ "$now" != "$was" ] || return 0
    _make_base_claude_dir "$2" && cs_write_atomic "$base" _settings_rules_union "$base" "$feat"
}

# Make the base's .claude for its settings file. cs_mkdir_inside makes
# directories only inside a .cs, and .claude sits beside it, one level under
# a base checkout that exists. So a .claude that is missing gets the same link
# check and then that one level, never the checkout above it; one that is
# there goes to cs_mkdir_inside for the link check alone, and one the base's
# own claude made in between counts as made.
_make_base_claude_dir() {  # base_dir
    local dir="$1/.claude" err
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        cs_mkdir_inside "$dir"
        return
    fi
    _cs_refuses_write cs_mkdir_inside "$dir" "$1" && return 1
    err=$(mkdir "$dir" 2>&1) || [ -d "$dir" ] || { printf '%s\n' "$err" >&2; return 1; }
}

# Remove the temp worktree and release the mutex on every exit path of
# integrate_feature_worktree, including error's exit 1. Globals because an
# EXIT trap runs after the function's locals are gone.
_integrate_cleanup() {
    if [ -n "${_INTEGRATE_TMP:-}" ]; then
        # Remove if present, then prune regardless: a directory gone with its
        # registration surviving is exactly what prune exists for. A temp
        # that cannot be removed must not abort the handler under set -e:
        # the lock below still has to be released.
        if [ -d "$_INTEGRATE_TMP" ]; then
            git -C "$_INTEGRATE_BASE_DIR" worktree remove --force "$_INTEGRATE_TMP" >/dev/null 2>&1 \
                || { rm -rf "$_INTEGRATE_TMP" 2>/dev/null || :; }
        fi
        git -C "$_INTEGRATE_BASE_DIR" worktree prune >/dev/null 2>&1 || true
    fi
    # A run terminated mid-gate still holds the gate's output log. A log that
    # cannot be removed must not abort the handler under set -e: the lock
    # below still has to be released.
    [ -n "${_INTEGRATE_GATE_LOG:-}" ] && { rm -f "$_INTEGRATE_GATE_LOG" 2>/dev/null || :; }
    # A lock already gone must not abort the handler under set -e: the path
    # still has to be forgotten below.
    [ -n "${_INTEGRATE_LOCK:-}" ] && { rm -r "$_INTEGRATE_LOCK" 2>/dev/null || :; }
    # A TERM'd run cleans up twice, from the signal handler and then from EXIT.
    # Forgetting the paths after the first pass keeps the second from removing
    # a lock or temp another integrate has since taken.
    _INTEGRATE_LOCK=""
    _INTEGRATE_TMP=""
    _INTEGRATE_GATE_LOG=""
    return 0
}

# Integrate a feature worktree's captured commit into the base session while
# the feature stays open: merge base HEAD + <sha> in a temporary detached
# worktree, run the gates there, fast-forward the base onto the result. Removes
# nothing — the worktree, the branch and the feature session all remain until
# retire_feature_worktree, the same skill's closing step. Backs the unadvertised
# `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate...>`
# that skills/finish/scripts/finish.sh drives. Every refusal is an error that
# names the next command.
integrate_feature_worktree() {  # base_name task sha [--from-remote [--ci-green]] -- gate...
    local usage="Usage: cs <base> -integrate-feature <task> <sha> [--from-remote [--ci-green]] -- <gate command...>"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3"
    shift 3
    local from_remote="" ci_green=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-remote) from_remote=1; shift ;;
            # The caller vouches that the PR's checks passed on the landing
            # commit; the entry has no GitHub access and never infers it.
            --ci-green) ci_green=1; shift ;;
            --) shift; break ;;
            *) error "$usage" ;;
        esac
    done
    [ -z "$ci_green" ] || [ -n "$from_remote" ] || error "$usage (--ci-green needs --from-remote: it describes the landing commit's checks on origin)"
    [ $# -gt 0 ] || error "$usage (a gate command is required; pass -- true to run none)"

    local base_dir wt_dir branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_dir="$SESSIONS_ROOT/$base_name@$task"
    branch="cs/$task"
    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    _finish_progress_begin "$base_dir" "$task"
    _require_base_commit "$base_dir" "$base_name"
    # Herestring, not a pipe: grep -q's early exit would SIGPIPE the writer
    # and pipefail would read that as "not registered".
    local features
    features=$(_worktree_features "$base_name")
    grep -qxF -- "$task" <<< "$features" \
        || error "$wt_dir is not a registered worktree of $base_name (see: git -C \"$base_dir\" worktree list)"

    # Only the base lock matters: the feature worktree is never touched, so
    # its conversation may stay open. A live base that is not this
    # conversation is a refusal, never a wait.
    local pid
    pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs")
    [ -z "$pid" ] || error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"

    local commit
    commit=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    sha="$commit"
    _FINISH_SHA="$sha"
    # Before the split: a detached base has no branch to land on either way,
    # and the ff-only would move a detached HEAD while the branch stays put.
    local base_branch
    base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null) \
        || error "Base checkout is detached; check out the branch to land on (for a PR, the branch it targets), then re-run"
    if [ -n "$from_remote" ]; then
        git -C "$base_dir" merge-base --is-ancestor "$sha" "refs/remotes/origin/$base_branch" 2>/dev/null \
            || error "$sha is not reachable from origin/$base_branch; run: git -C \"$base_dir\" fetch origin, then check the PR's base branch"
    else
        git -C "$base_dir" merge-base --is-ancestor "$sha" "$branch" 2>/dev/null \
            || error "$sha is not reachable from $branch; capture the feature HEAD again"
    fi
    # Nothing to land: the record gains no step, and the retire that follows
    # writes the outcome.
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'already-integrated %s %s\n' "$task" "$sha"
        return 0
    fi
    _finish_progress_write started

    if _tree_is_dirty "$base_dir"; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi
    local git_dir common
    git_dir=$(_git_path_abs "$base_dir" --git-dir) || error "Not a git checkout: $base_dir"
    common=$(_git_path_abs "$base_dir" --git-common-dir) || error "Not a git checkout: $base_dir"
    if git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
        || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        error "Base checkout has a merge or rebase in progress; finish or abort it, then re-run"
    fi

    # The mutex the autosave hook honours (hooks/autosave-commits.sh spells
    # the same path). Per-CHECKOUT, not per-clone: the base is always a main
    # checkout, so its --git-dir is the common dir, while a feature
    # worktree's autosave takes its own private gitdir's lock and never
    # contends with this integrate — the feature conversation stays open and
    # keeps snapshotting throughout a gate run. An existing directory is a
    # refusal, never stolen: a stale one is the user's to inspect and remove
    # (cs -doctor names it).
    local lock="$git_dir/cs/integrate.lock"
    mkdir -p "$git_dir/cs"
    # The base's own autosave takes this same lock for the length of one tree
    # write, so a refusal on the first try is far more often a snapshot in
    # flight than another integrate. Five tries a second apart outlast that
    # and still refuse promptly on a genuinely held lock.
    local tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            error "Another integrate or an in-flight autosave holds $lock; wait a few seconds and re-run. Remove that directory only if it persists with no cs running"
        fi
        sleep 1
    done
    _INTEGRATE_LOCK="$lock"
    _INTEGRATE_BASE_DIR="$base_dir"
    _INTEGRATE_TMP=""
    _INTEGRATE_GATE_LOG=""
    # EXIT alone is not enough: a TERM/INT'd bash skips the EXIT trap
    # (measured: exit 143, no cleanup), stranding the mutex and the temp.
    # Same shape as lib/75-launch.sh:112-113. Armed before the pid write: a
    # write that fails under set -e must still release the directory. The
    # progress handler goes first, while $? is still the exit status.
    trap '_finish_progress_exit "$?"; _integrate_cleanup' EXIT
    trap '_integrate_cleanup; exit 130' INT TERM
    # The holder's pid, for cs -doctor's liveness check. Inside the lock, so
    # the directory and its evidence are created and removed together; the
    # autosave hook's own brief hold records nothing and releases with rmdir.
    echo "$$" > "$lock/pid"

    _integrate_in_temp "$base_dir" "$wt_dir" "$task" "$sha" "$common" "$from_remote" "$ci_green" "$@"
}

# The mutation half of integrate_feature_worktree, entered with the mutex
# held and the cleanup trap armed: merge base HEAD + <sha> in a temporary
# detached worktree under $TMPDIR, run the gate argv there, then
# fast-forward the base onto the result. The fast-forward is the atomic
# "base has not moved" check; a red gate or a conflict leaves base exactly
# as it was. No hook of the project fires inside the temp (core.hooksPath
# points at an empty directory for the add and the merge): the gate argv is
# the project's gate, run explicitly.
_integrate_in_temp() {  # base_dir wt_dir task sha common from_remote ci_green gate...
    local base_dir="$1" wt_dir="$2" task="$3" sha="$4" common="$5" from_remote="$6" ci_green="$7"
    shift 7

    local B
    B=$(git -C "$base_dir" rev-parse HEAD)
    # Before 2a92ac67 the temp lived under <common>/cs/finish/, so a run killed
    # then can have left a <task>.<pid> directory there. Nothing reads that
    # path any more, and removing it would mean cs deleting inside an adopted
    # repo's .git for no change in behaviour (#838). Leave it; do not add a sweep.
    # Outside any .git directory: tools refuse to serve or read files under
    # one (Vite's server.fs.deny holds **/.git/**, so a vitest browser run in
    # the temp never connects and the gate goes red for where it ran). An
    # empty directory, which git worktree add fills.
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cs-finish-$task.XXXXXX") \
        || error "Could not create a temporary directory for the integrate under ${TMPDIR:-/tmp}"
    # Armed as soon as the directory exists, before the add: an add that fails
    # half-way leaves a directory and a registration behind, and only a
    # _INTEGRATE_TMP the cleanup can see gets them removed. The cleanup
    # removes a directory that never became a worktree and prunes either way.
    _INTEGRATE_TMP="$tmp"
    # /dev/null is not a directory on BSD, so hooks are silenced with a real
    # empty one.
    local no_hooks
    no_hooks=$(mktemp -d "${TMPDIR:-/tmp}/cs-nohooks.XXXXXX")
    if ! git -C "$base_dir" -c core.hooksPath="$no_hooks" worktree add --detach "$tmp" "$B" >/dev/null 2>&1; then
        rmdir "$no_hooks"
        error "git worktree add failed for $tmp"
    fi

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    if [ "$mode" = "tracked" ]; then
        _setup_merge_attributes_clone_local "$base_dir" "$common"
        _warn_memory_index_changed "$base_dir" "$sha"
    fi

    # --no-ff locally: the merge commit names the feature and is the audit
    # trail /finish leaves, and it gives the retire verb's ancestor check
    # something to find. --from-remote: the landing commit already exists on
    # origin and names the PR, so a fast-forward is the right shape there.
    local sha7 merge_status=0
    sha7=$(printf '%s' "$sha" | cut -c1-7)
    _finish_progress_write merging
    if [ -n "$from_remote" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-edit "$sha" >/dev/null 2>&1 || merge_status=$?
    else
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-ff --no-edit \
            -m "Merge feature $task ($sha7)" "$sha" >/dev/null 2>&1 || merge_status=$?
    fi
    # The merge commit this integrate will land, read before the gate runs.
    # Everything after the gate is measured against it: what lands is this
    # commit, never whatever the temp holds when the gate is done.
    # merge=ours kept the base's MEMORY.md; a pointer to a topic only the
    # feature indexed is appended and folded into the merge commit, so it
    # lands with it. A --from-remote landing is origin's commit, left as is.
    if [ "$merge_status" = 0 ] && [ "$mode" = "tracked" ] && [ -z "$from_remote" ] \
        && git -C "$tmp" cat-file -e "$sha:.cs/memory/MEMORY.md" 2>/dev/null; then
        local feature_index added
        feature_index=$(mktemp "${TMPDIR:-/tmp}/cs-memory-index.XXXXXX")
        if ! git -C "$tmp" show "$sha:.cs/memory/MEMORY.md" > "$feature_index" \
            || ! added=$(_append_missing_memory_pointers "$feature_index" "$tmp/.cs/memory/MEMORY.md"); then
            rm -f "$feature_index"; rmdir "$no_hooks"
            error "Could not carry the feature's MEMORY.md pointers into the merge in $tmp; base untouched"
        fi
        rm -f "$feature_index"
        if [ "$added" != 0 ]; then
            git -C "$tmp" add -- .cs/memory/MEMORY.md \
                && git -C "$tmp" -c core.hooksPath="$no_hooks" commit -q --amend --no-edit >/dev/null \
                || { rmdir "$no_hooks"; error "Could not commit the feature's MEMORY.md pointers in $tmp; base untouched"; }
            info "MEMORY.md: appended $added pointer(s) from the feature (base lines kept)"
        fi
    fi
    local M=""
    [ "$merge_status" = 0 ] && M=$(git -C "$tmp" rev-parse HEAD)
    if [ "$merge_status" != 0 ]; then
        rmdir "$no_hooks"
        local conflicts base_branch advice
        conflicts=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null || true)
        base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)
        if [ -n "$from_remote" ]; then
            # Nothing of the feature's is in this conflict: it is the base's
            # own commits against what origin carries, so the feature worktree
            # is the wrong place to fix it.
            advice="Resolve it in the base (git -C \"$base_dir\" merge origin/$base_branch): the conflict is between $base_dir's local commits and origin's $base_branch, not with the feature. Then re-run /finish $task"
        else
            advice="Resolve on the feature branch (git merge $base_branch in $wt_dir), then re-run /finish $task"
        fi
        error "Merge of $sha conflicts with $base_dir at $B; base untouched. Conflicting paths:
${conflicts:-(none reported; see git -C \"$tmp\" status)}
$advice"
    fi
    # An untracked file in the base colliding with a path the merge touches
    # passes _tree_is_dirty (tracked-only) and the temp merge itself, then
    # aborts the ff-only landing with a message that blames the wrong cause.
    # Caught here, before the gate spends any cost on a doomed landing.
    local touched_file others_file collisions
    touched_file=$(mktemp "${TMPDIR:-/tmp}/cs-touched.XXXXXX")
    others_file=$(mktemp "${TMPDIR:-/tmp}/cs-untracked.XXXXXX")
    git -C "$tmp" diff --name-only "$B" HEAD > "$touched_file"
    git -C "$base_dir" ls-files --others --exclude-standard > "$others_file"
    collisions=""
    if [ -s "$touched_file" ] && [ -s "$others_file" ]; then
        collisions=$(grep -Fxf "$touched_file" "$others_file" 2>/dev/null || true)
    fi
    rm -f "$touched_file" "$others_file"
    if [ -n "$collisions" ]; then
        rmdir "$no_hooks"
        error "Untracked files in $base_dir collide with paths the feature adds; base untouched. Colliding paths:
$collisions
Move or delete these untracked files in $base_dir, then re-run /finish $task"
    fi
    # Submodules after the merge, so the gates see the MERGED gitlinks: a
    # feature that adds or bumps a submodule is otherwise gated against
    # absent or stale contents.
    if [ -f "$tmp/.gitmodules" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" submodule update --init --recursive -q >/dev/null 2>&1 \
            || { rmdir "$no_hooks"; error "submodule update failed in $tmp"; }
    fi
    rmdir "$no_hooks"

    # A remote landing whose base has nothing origin lacks fast-forwards onto
    # the PR's landing commit; the temp holds exactly that tree. When the
    # caller vouches (--ci-green) that origin's checks passed on that very
    # commit, a local gate would only repeat them in a checkout without the
    # project's gitignored dependencies, so skip it and say so. A base carrying
    # its own commits makes a merge those checks never saw, and then the gate
    # runs.
    local gate_skipped="" B7
    B7=$(printf '%s' "$B" | cut -c1-7)
    if [ -n "$from_remote" ] && [ -n "$ci_green" ] \
        && git -C "$base_dir" merge-base --is-ancestor "$B" "$sha" 2>/dev/null; then
        gate_skipped=1
        echo "gate skipped: $base_dir at $B7 fast-forwards onto $sha7, whose checks passed on origin; nothing local to test"
    fi
    if [ -z "$gate_skipped" ]; then
        # `-- true` is how the caller says there is no gate: nothing worth a
        # band runs, so only a real gate is a step of the record.
        if [ $# -ne 1 ] || [ "$1" != true ]; then
            _FINISH_GATE_STARTED=$(date +%s)
            _finish_progress_write gate
        fi
        # A global, so _integrate_cleanup removes it when the run is
        # terminated mid-gate.
        _INTEGRATE_GATE_LOG=$(mktemp "${TMPDIR:-/tmp}/cs-gate.XXXXXX")
        # </dev/null: a gate that reads stdin would otherwise consume whatever
        # cs was given and block a non-interactive run forever.
        if ! (cd -- "$tmp" && "$@") > "$_INTEGRATE_GATE_LOG" 2>&1 < /dev/null; then
            cat "$_INTEGRATE_GATE_LOG" >&2
            rm -f "$_INTEGRATE_GATE_LOG"
            _INTEGRATE_GATE_LOG=""
            error "Gate failed in $tmp (output above); base $base_dir untouched at $B
The gate ran in a clean checkout of the merged commit: gitignored files (installed dependencies, .env, build output) are not there. A gate that needs them must create them first, e.g. -- sh -c 'npm ci && npm test'"
        fi
        rm -f "$_INTEGRATE_GATE_LOG"
        _INTEGRATE_GATE_LOG=""
    fi

    # A green gate that changed the temp is still a refusal. What lands is M,
    # so a file the gate wrote is either dropped on the floor or — once the
    # gate commits it — rides into the base unreviewed. Generated output
    # belongs on the feature branch, committed by the person who ran the build.
    local gate_head gate_dirt tampered
    gate_head=$(git -C "$tmp" rev-parse HEAD 2>/dev/null || echo "")
    gate_dirt=$(git -C "$tmp" status --porcelain --untracked-files=no 2>/dev/null || true)
    tampered=""
    if [ -n "$gate_dirt" ]; then
        tampered="tracked files or submodules changed:
$gate_dirt"
    fi
    if [ "$gate_head" != "$M" ]; then
        tampered="${tampered:+$tampered
}HEAD moved to ${gate_head:-(unreadable)}"
    fi
    if git -C "$tmp" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        tampered="${tampered:+$tampered
}a merge is in progress"
    fi
    if [ -n "$tampered" ]; then
        error "The gate changed the temp checkout; base $base_dir untouched at $B. What the gate changed:
$tampered
Commit the generated output on the feature branch, then re-run /finish $task"
    fi

    # Re-verify the base immediately before landing. --ff-only alone is not
    # the "base unchanged" check: a base reset to an ancestor of B still
    # fast-forwards, and unrelated tracked dirt survives one. The residual
    # window between this check and the merge is the one race left; the
    # mutex keeps cs's own writer (the autosave hook) out of it.
    if [ "$(git -C "$base_dir" rev-parse HEAD)" != "$B" ]; then
        error "Base $base_dir moved during the gates (was $B, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish $task"
    fi
    if _tree_is_dirty "$base_dir" || git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        error "Base $base_dir changed during the gates (uncommitted changes or a merge in progress); commit or abort, then re-run /finish $task"
    fi
    # Fast-forward BEFORE removing the temp: until then the merge commit is
    # reachable only from the temp's detached HEAD.
    local R ff_err ff_status=0
    R="$M"
    _finish_progress_write fast-forward
    ff_err=$(git -C "$base_dir" merge --ff-only "$R" 2>&1 >/dev/null) || ff_status=$?
    if [ "$ff_status" != 0 ]; then
        error "Base $base_dir moved or changed during the gates (was $B); re-run /finish $task
${ff_err:-(no output from git merge --ff-only)}"
    fi
    # The base's landing is the one merge that runs with the project's hooks
    # live — it is the user's checkout, and a post-merge hook is entitled to
    # fire there. One that commits leaves base past the commit cs landed, so
    # read HEAD back and report where the base actually is.
    local landed
    landed=$(git -C "$base_dir" rev-parse HEAD)
    if [ "$landed" != "$R" ]; then
        warn "A post-merge hook moved $base_dir to $landed after landing $R"
    fi
    # Keep _INTEGRATE_TMP until the removal is verified, so the EXIT cleanup
    # still has the path if this removal fails; a leftover temp is reported,
    # never silently forgotten.
    if git -C "$base_dir" worktree remove --force "$tmp" >/dev/null 2>&1; then
        _INTEGRATE_TMP=""
    else
        warn "Temporary worktree $tmp could not be removed; run: git -C \"$base_dir\" worktree remove --force \"$tmp\""
    fi

    # The feature's tree has landed in the base, and nothing has scanned it
    # since the base opened: a link the feature committed here is refused
    # by the append, never written through.
    _append_record "$base_dir/.cs/timeline.jsonl" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "feature-integrated" \
           --arg task "$task" \
           --arg sha "$sha" \
           --arg result "$landed" \
        '{ts: $ts, event: $event, task: $task, sha: $sha, result: $result}'
    _finish_progress_write landed result "$landed"
    printf 'integrated %s %s -> %s\n' "$task" "$sha" "$landed"
}

# Append one JSONL file onto another, keeping every record on its own line. A
# process killed mid-write leaves a last line with no newline; a bare `cat >>`
# then splices two records into one, and the tolerant per-line reader
# (`fromjson? // empty` in run_conversations) drops BOTH the splice and the
# record that followed it. Terminating on either side costs one byte and keeps
# the loss at zero. Fails, appending nothing, when a link takes <dst> out of
# its session.
_append_jsonl() {  # src dst
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    _terminate_jsonl "$dst"
    cs_append_inside "$dst" cat "$src" || return 1
    _terminate_jsonl "$dst"
}

# A log fused onto another starts on a line of its own.
_blank_line_then_cat() {  # file
    echo ""
    cat "$1"
}

# Append to the base's memory index each "- [title](target)" pointer of the
# feature's index whose target the base index does not name, once per target,
# and print how many were appended. The base's own lines stay as they are (a
# pointer both sides reworded keeps the base wording); only a pointer to a
# topic the base has never indexed is added, so it is not lost at /finish.
# A pointer the base's memory archive (reference_memory_archive.md beside the
# index) names is indexed there: /wrap's memory pass moved it out of
# MEMORY.md, and it stays out. Given the two archives, it folds the archive
# the same way: the base archive is then both files it reads.
# A pointer whose topic file is not beside the base index is left out: the
# base deleted that topic after the feature branched, and the deletion stands.
# Fails, appending nothing, when a link takes the base index out of its
# session: a feature can commit MEMORY.md as a link, and a merge installs it.
_append_missing_memory_pointers() {  # feature_index base_index
    local src="$1" dst="$2" have="$2" archive="${2%/*}/reference_memory_archive.md" missing
    [ -f "$src" ] || { printf '0'; return 0; }
    [ -f "$dst" ] || have=/dev/null
    [ -f "$archive" ] || archive=/dev/null
    # Bytes, not characters: the index is UTF-8 in any locale, and awk stops
    # on a line a multibyte locale cannot decode. Every file but the last
    # (the feature's index) names targets the base already indexes.
    missing=$(env LC_ALL=C awk '
        function target(s) {
            if (s !~ /^- \[/ || !match(s, /]\([^)]*\)/)) return ""
            return substr(s, RSTART + 2, RLENGTH - 3)
        }
        FILENAME != ARGV[ARGC - 1] { t = target($0); if (t != "") seen[t] = 1; next }
        { t = target($0); if (t == "" || (t in seen)) next; seen[t] = 1; print t "\t" $0 }
    ' "$have" "$archive" "$src") || return 1
    local entry kept="" tab="	"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        [ -f "${dst%/*}/${entry%%"$tab"*}" ] || continue
        kept="$kept${entry#*"$tab"}"$'\n'
    done <<< "$missing"
    missing=$(printf '%s' "$kept")
    [ -n "$missing" ] || { printf '0'; return 0; }
    _terminate_jsonl "$dst"
    cs_append_inside "$dst" printf '%s\n' "$missing" || return 1
    printf '%s' "$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
}

# Print the record of the copy the create put at <rel> in a feature's .cs,
# nothing when the create put no file there (or one it could not record).
# Fails when a record may be there and cannot be read: a directory on its way
# cannot be searched, or the record cannot be read. Answering "the feature
# wrote it" then would bring a file the base deleted back, or call a copy
# the feature never touched an edit.
_inherited_sum() {  # feature_meta rel
    local record dir rest
    _inherited_record_path "$1" "$2"
    record="$_CS_INHERITED_RECORD"
    dir="$1/local"
    rest="${record#"$dir"/}"
    while case "$rest" in */*) true ;; *) false ;; esac; do
        dir="$dir/${rest%%/*}"
        rest="${rest#*/}"
        [ -e "$dir" ] || [ -L "$dir" ] || return 0
        [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
    done
    [ -e "$record" ] || [ -L "$record" ] || return 0
    cat "$record"
}

# What the record fuse does with one file of a feature's .cs, given relative
# to it, against the base's .cs:
#   carry    the base has no file there: it gets the feature's
#   restore  the same, for a copy the create handed over, the base deleted
#            and the feature edited: the edit comes back, named
#   replace  the create handed over a copy, the feature edited it and the base
#            did not: the feature's version replaces the base's, named
#   skip     nothing to carry: the base holds the same bytes, or the feature
#            left the copy it was handed as it was
#   conflict carrying it would overwrite a different file in the base, the
#            base holds a file where it needs a directory or a link that
#            takes it out of the session, or it is a link or not a regular
#            file
# Fails when the record of the copy, or the file, cannot be read.
_fuse_verdict() {  # feature_meta base_meta rel
    local src="$1/$3" dst="$2/$3" was now
    if [ -L "$src" ] || [ ! -f "$src" ]; then echo conflict; return 0; fi
    was=$(_inherited_sum "$1" "$3") || return 1
    if [ -n "$was" ]; then
        now=$(cksum < "$src") || return 1
        if [ "$now" = "$was" ]; then echo skip; return 0; fi
    fi
    if _fuse_path_blocked "$2" "$3"; then echo conflict; return 0; fi
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
        if [ -n "$was" ]; then echo restore; else echo carry; fi
        return 0
    fi
    if [ -L "$dst" ] || [ ! -f "$dst" ]; then echo conflict; return 0; fi
    if cmp -s "$src" "$dst"; then echo skip; return 0; fi
    if [ -n "$was" ] && [ "$(cksum < "$dst")" = "$was" ]; then echo replace; else echo conflict; fi
}

# Whether the fuse cannot make the directories on the way to <rel> in the
# base's .cs. It makes them with cs_mkdir_inside, which cannot make one where
# the base holds a file or a dangling link, refuses to make a new directory
# named .cs (_cs_mkdir_spelling_refused), and refuses one a link takes out of
# the session. A link that stays inside (an encrypted session's .cs/memory,
# say) is a directory like any other.
_fuse_path_blocked() {  # base_meta rel
    local dir="$1" rest="$2" near="$1" linked="" missing=""
    while case "$rest" in */*) true ;; *) false ;; esac; do
        dir="$dir/${rest%%/*}"
        rest="${rest#*/}"
        [ ! -L "$dir" ] || linked=1
        if [ -e "$dir" ]; then
            [ -d "$dir" ] || return 0
            near="$dir"
        elif [ -L "$dir" ]; then
            return 0
        else
            missing=1
            break
        fi
    done
    if [ -n "$missing" ] && _cs_mkdir_spelling_refused "$1/${2%/*}" "$near"; then
        return 0
    fi
    [ -n "$linked" ] && _cs_refuses_write cs_mkdir_inside "$1/$2" "$near" 2>/dev/null
}

# Whether fuse_session_records cannot merge the feature's <rel> into the
# base's <dst_rel>: it merges only a regular file, into a regular file or
# none, at the end of a path _fuse_path_blocked lets it make.
_fuse_merge_blocked() {  # feature_meta base_meta rel dst_rel
    local dst="$2/$4"
    if [ -L "$1/$3" ] || [ ! -f "$1/$3" ]; then return 0; fi
    if _fuse_path_blocked "$2" "$4"; then return 0; fi
    if [ -L "$dst" ]; then return 0; fi
    [ -e "$dst" ] && [ ! -f "$dst" ]
}

# Where a feature's .cs can hold a log, relative to it, in the order
# fuse_session_records appends them to the base's: cs wrote at logs/ until
# the log moved to local/, so the lines at logs/ are the earlier ones.
CS_FUSED_LOGS="logs/session.log local/session.log"

# The files of a feature's .cs that _fuse_plan's walk passes over: cs's
# machine-local bookkeeping, which goes with the worktree, and the log, which
# _fuse_plan checks apart: the fuse appends it to the base's machine-local
# log, not to the same path.
_fuse_walk_skips() {  # rel
    case "$1" in
        local/*|session.lock|session.mutex.lock|.narrative-reminder-cooldown) return 0 ;;
        logs/session.log|.DS_Store|*/.DS_Store) return 0 ;;
    esac
    return 1
}

# The files of a feature's .cs that fuse_session_records merges into the
# same path of the base's by a rule of its own: the timeline, the narratives,
# the memory index and the memory archive.
_fuse_merged_record() {  # rel
    case "$1" in
        timeline.jsonl|memory/MEMORY.md|memory/reference_memory_archive.md) return 0 ;;
        memory/narrative.*.md)
            case "${1#memory/}" in */*) return 1 ;; esac
            return 0 ;;
    esac
    return 1
}

# The files of a feature's .cs that are the feature's own prose rather than
# records it shares with the base: the README cs wrote for it, whose objective
# the feature fills in, and summary.md, which its /wrap rewrites. One the
# feature changed goes to the base under the feature's path,
# .cs/features/<task>/ (_fuse_feature_verdict), never over the base's own.
_fuse_feature_prose() {  # rel
    case "$1" in
        README.md|summary.md) return 0 ;;
    esac
    return 1
}

# Where the feature's <rel>, a _fuse_feature_prose file, goes in the base,
# relative to its .cs: the first of features/<task>/<rel>, then <stem>.2.md,
# <stem>.3.md and on, that holds nothing, so an earlier feature of the same
# name keeps what it left there. Sets _CS_FEATURE_DEST to that name, or to
# nothing when one of the names before it is a file of the base's own (not a
# link) with the same bytes: the feature's copy is there already.
_fuse_feature_dest() {  # feature_meta base_meta rel task
    local dir="features/$4" stem="${3%.md}" name="$3" n=1
    while [ -e "$2/$dir/$name" ] || [ -L "$2/$dir/$name" ]; do
        if [ ! -L "$2/$dir/$name" ] && [ -f "$2/$dir/$name" ] && cmp -s "$1/$3" "$2/$dir/$name"; then
            _CS_FEATURE_DEST=""
            return 0
        fi
        n=$((n + 1))
        name="$stem.$n.md"
    done
    _CS_FEATURE_DEST="$dir/$name"
}

# What the record fuse does with a _fuse_feature_prose file of a feature's
# .cs, given relative to it, against the base's .cs:
#   skip     the feature left the copy the create handed it (or wrote for it)
#            as it was, or the base holds the same bytes under the feature's
#            path already
#   feature  it goes to the base under the feature's path (_fuse_feature_dest)
#   conflict it is a link or not a regular file
#   blocked  <task> is no feature name cs accepts, or the base cannot take the
#            directories on the way to features/<task>/ (_fuse_path_blocked)
# Fails when the record of the copy, or the file, cannot be read.
_fuse_feature_verdict() {  # feature_meta base_meta rel task
    local src="$1/$3" was now
    if [ -L "$src" ] || [ ! -f "$src" ]; then echo conflict; return 0; fi
    was=$(_inherited_sum "$1" "$3") || return 1
    if [ -n "$was" ]; then
        now=$(cksum < "$src") || return 1
        if [ "$now" = "$was" ]; then echo skip; return 0; fi
    fi
    if ! _feature_name_ok "$4" || _fuse_path_blocked "$2" "features/$4/$3"; then
        echo blocked
        return 0
    fi
    _fuse_feature_dest "$1" "$2" "$3" "$4"
    if [ -n "$_CS_FEATURE_DEST" ]; then echo feature; else echo skip; fi
}

# Write to <out> one NUL-terminated "<verdict> <rel>" for every file of a
# feature's .cs the fuse copies (_fuse_verdict, and _fuse_feature_verdict for
# the feature's own prose, which goes under the feature's path for <task>), and
# "conflict <rel>" for one it merges that it cannot (_fuse_merge_blocked). A directory holding a .git
# is a repository nested under .cs: written once as "conflict <rel>/" and
# never walked, and .cs itself holding one is written as "conflict " with an
# empty path. Links are listed, never followed. Fails, naming the file, when
# one cannot be classified, and when the walk fails.
_fuse_plan() {  # feature_meta base_meta out task
    local list rel verdict logdir
    : > "$3" || return 1
    [ -d "$1" ] && [ ! -L "$1" ] || return 0
    if [ -e "$1/.git" ] || [ -L "$1/.git" ]; then
        printf 'conflict \0' >> "$3"
        return 0
    fi
    # A link at local/ would have the fuse read the log from wherever it
    # leads. The walk below prunes local/ and so never sees it; it is named
    # here. A link at logs/ the walk names like any other link.
    [ ! -L "$1/local" ] || printf 'conflict local\0' >> "$3"
    # The fuse appends each log the feature has (CS_FUSED_LOGS) to the base's
    # machine-local one. A locked vault has no machine-local log to check
    # against; the retire refuses it by name.
    if logdir=$(cs_private_dir "$2"); then
        for rel in $CS_FUSED_LOGS; do
            [ -e "$1/$rel" ] || [ -L "$1/$rel" ] || continue
            if _fuse_merge_blocked "$1" "$2" "$rel" "${logdir#"$2"/}/session.log"; then
                printf 'conflict %s\0' "$rel" >> "$3"
            fi
        done
    fi
    list=$(mktemp "${TMPDIR:-/tmp}/cs-fuse-list.XXXXXX") || return 1
    # local/ is machine-local (_fuse_walk_skips) and never walked. The walk
    # is sorted so the first record it refuses, named in the error, is the
    # same on every filesystem (pipefail keeps a failed find failing).
    if ! (cd -- "$1" && find . -mindepth 1 \( -path ./local -prune \) \
            -o \( -type d -exec test -e '{}/.git' \; -prune -print0 \) \
            -o \( ! -type d -print0 \) | LC_ALL=C sort -z) > "$list"; then
        rm -f "$list"
        return 1
    fi
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        if [ -d "$1/$rel" ] && [ ! -L "$1/$rel" ]; then
            printf 'conflict %s/\0' "$rel" >> "$3"
            continue
        fi
        _fuse_walk_skips "$rel" && continue
        if _fuse_merged_record "$rel"; then
            if _fuse_merge_blocked "$1" "$2" "$rel" "$rel"; then
                printf 'conflict %s\0' "$rel" >> "$3"
            fi
            # The fuse reads the archive's record after the removal, to tell
            # whether the feature changed it; one it cannot read fails here.
            if [ "$rel" = memory/reference_memory_archive.md ] && ! _inherited_sum "$1" "$rel" > /dev/null; then
                warn "could not read what the feature inherited for $rel, so cs cannot tell whether the base deleted or changed it" >&2
                rm -f "$list"
                return 1
            fi
            continue
        fi
        if _fuse_feature_prose "$rel"; then
            verdict=$(_fuse_feature_verdict "$1" "$2" "$rel" "$4")
        else
            verdict=$(_fuse_verdict "$1" "$2" "$rel")
        fi || {
            warn "could not read what the feature inherited for $(_printable_name "$rel"), so cs cannot tell whether the base deleted or changed it" >&2
            rm -f "$list"
            return 1
        }
        printf '%s %s\0' "$verdict" "$rel" >> "$3"
    done < "$list"
    rm -f "$list"
}

# The files of a feature's .cs the record fuse cannot carry into the base,
# one per line as "<verdict> .cs/<rel>", sorted, each name as a message prints
# it (_printable_name): "conflict" for one to merge by hand, "blocked" for the
# feature's own prose whose path under .cs/features/<task>/ the base blocks
# (_fuse_feature_verdict).
# Retire refuses on any; the features screen counts them. Fails when the
# classification fails.
_fuse_conflicts() {  # feature_meta base_meta task
    local plan entry out=""
    plan=$(mktemp "${TMPDIR:-/tmp}/cs-fuse-plan.XXXXXX") || return 1
    if ! _fuse_plan "$1" "$2" "$plan" "$3"; then
        rm -f "$plan"
        return 1
    fi
    while IFS= read -r -d '' entry; do
        case "$entry" in
            "conflict "*|"blocked "*)
                out="$out${entry%% *} .cs/$(_printable_name "${entry#* }")"$'\n' ;;
        esac
    done < "$plan"
    rm -f "$plan"
    [ -z "$out" ] || printf '%s' "$out" | env LC_ALL=C sort
}

# Fuse session records from a worktree .cs into the base .cs (ignored mode:
# the repo does not track .cs/, so git merge cannot carry these). Applies the
# same semantics the merge drivers give tracked repos: union append for
# timeline/log/narratives, base-wins for MEMORY.md and the memory archive plus
# the feature's pointers to targets each lacks. Every other file goes back by _fuse_verdict: one the
# base lacks is copied in, a copy only the feature edited replaces the base's,
# and none ever overwrites a base file that changed. The feature's own README
# and summary, once it changed them, go to .cs/features/<task>/ instead
# (_fuse_feature_verdict), beside any an earlier feature of that name left.
# Every write returns 1 on failure: the caller runs
# this in a subshell on the left of ||, where errexit is off, and deletes the
# staged records only on success. Every write also goes through the link
# check: the landing put the feature's tree in the base, and nothing has
# scanned the base since. A write that fails leaves the earlier ones in the
# base, so the staged records can repeat some the base already holds; the
# caller's error says to fuse what is missing. No pass checks every
# destination before the first write: a full disk leaves the same state, and
# that pass would have to list the destinations a second time.
fuse_session_records() {  # feature_meta base_meta task
    local src="$1" dst="$2" task="$3"
    local f base

    # Worktrees never run migrate_session, so a task branch created before the
    # log moved to .cs/local/ still keeps its audit trail at .cs/logs/, and
    # one used since has a log at .cs/local/ as well; fuse each the worktree
    # has into the base's machine-local log, the one at .cs/logs/ first: its
    # lines are the earlier ones.
    # An encrypted base keeps its log behind .cs/private; a locked one cannot
    # take the log, and .cs/local must not take it in plaintext instead.
    # Resolved before any write, so that refusal leaves the base untouched.
    local srclog dstlog=""
    for srclog in $CS_FUSED_LOGS; do
        if [ -f "$src/$srclog" ]; then
            dstlog=$(cs_private_dir "$dst") \
                || error "cannot fuse the worktree's log: $dst/private is locked. Mount it, then retry."
            break
        fi
    done

    _append_jsonl "$src/timeline.jsonl" "$dst/timeline.jsonl" || return 1
    for srclog in $CS_FUSED_LOGS; do
        [ -f "$src/$srclog" ] || continue
        cs_mkdir_inside "$dstlog" || return 1
        cs_append_inside "$dstlog/session.log" _blank_line_then_cat "$src/$srclog" || return 1
    done

    # .cs/memory is made for a narrative to merge and for nothing else:
    # _fuse_plan checks the path of each it will merge, and a feature with
    # none must not fail on a base whose .cs/memory is a file.
    for f in "$src"/memory/narrative.*.md; do
        [ -f "$f" ] || continue
        cs_mkdir_inside "$dst/memory" || return 1
        base=$(basename "$f")
        if [ -f "$dst/memory/$base" ]; then
            # Append the body past the closing --- of the YAML frontmatter.
            # A file not opening with --- has no frontmatter (whole file is
            # body); counting stops at 2 so a --- horizontal rule in the
            # body stays body instead of truncating the append.
            # Bytes, not characters (LC_ALL=C): the records are UTF-8 in any
            # locale, and awk stops on one a multibyte locale cannot decode.
            cs_append_inside "$dst/memory/$base" \
                env LC_ALL=C awk 'NR==1 && $0 != "---" {c=2} /^---$/ && c < 2 {c++; next} c >= 2 {print}' "$f" || return 1
        else
            cs_write_atomic "$dst/memory/$base" cat "$f" || return 1
        fi
    done

    # Every other file goes by its verdict. The retire refused any conflict
    # before the removal; one here means the base changed since, and the
    # staged records stay for the caller's error to name.
    local plan entry verdict rel parent
    plan=$(mktemp "${TMPDIR:-/tmp}/cs-fuse-plan.XXXXXX") || return 1
    if ! _fuse_plan "$src" "$dst" "$plan" "$task"; then
        rm -f "$plan"
        return 1
    fi
    while IFS= read -r -d '' entry; do
        verdict="${entry%% *}"
        rel="${entry#* }"
        case "$verdict" in
            skip) continue ;;
            carry|restore|replace) ;;
            feature)
                # Named afresh: the base may hold more under the feature's
                # path than when the plan was made.
                _fuse_feature_dest "$src" "$dst" "$rel" "$task"
                [ -n "$_CS_FEATURE_DEST" ] || continue
                if ! { cs_mkdir_inside "$dst/features/$task" \
                        && cs_write_atomic "$dst/$_CS_FEATURE_DEST" cat "$src/$rel"; }; then
                    rm -f "$plan"
                    return 1
                fi
                info "The feature's $rel is kept at $dst/$_CS_FEATURE_DEST"
                continue ;;
            *)
                warn "$rel cannot be carried into the base without overwriting what is there"
                rm -f "$plan"
                return 1 ;;
        esac
        parent="$dst"
        case "$rel" in */*) parent="$dst/${rel%/*}" ;; esac
        if ! { cs_mkdir_inside "$parent" && cs_write_atomic "$dst/$rel" cat "$src/$rel"; }; then
            rm -f "$plan"
            return 1
        fi
        case "$verdict" in
            restore) warn "$(_printable_name "$rel") was deleted in the base and edited in the feature; the feature's version is back in the base" ;;
            replace) warn "$(_printable_name "$rel") was edited in the feature and not in the base; the feature's version is now in the base" ;;
        esac
    done < "$plan"
    rm -f "$plan"

    # The memory archive merges before the index, so the index append reads
    # the merged archive: a base with no archive takes the feature's whole,
    # frontmatter and all; one with an archive keeps it and gains each
    # feature pointer whose target it does not name, as a tracked session's
    # union merge gives it. An archive the feature left as it was handed
    # over brings nothing: the base's stays as it is, deletions and all, as
    # _fuse_verdict leaves every other file the feature left.
    local added archive="memory/reference_memory_archive.md" was="" now=""
    if [ -f "$src/$archive" ]; then
        was=$(_inherited_sum "$src" "$archive") || return 1
        if [ -n "$was" ]; then
            now=$(cksum < "$src/$archive") || return 1
        fi
    fi
    if [ -f "$src/$archive" ] && { [ -z "$was" ] || [ "$now" != "$was" ]; }; then
        if [ -f "$dst/$archive" ]; then
            added=$(_append_missing_memory_pointers "$src/$archive" "$dst/$archive") || return 1
            [ "$added" = 0 ] || info "reference_memory_archive.md: appended $added pointer(s) from the feature (base lines kept)"
        else
            { cs_mkdir_inside "$dst/memory" && cs_write_atomic "$dst/$archive" cat "$src/$archive"; } || return 1
        fi
    fi

    added=$(_append_missing_memory_pointers "$src/memory/MEMORY.md" "$dst/memory/MEMORY.md") || return 1
    [ "$added" = 0 ] || info "MEMORY.md: appended $added pointer(s) from the feature (base lines kept)"
}

# List a base session's feature worktrees with their merge readiness. Read
# only: this is a query, not a gate, so it exits 0 even when nothing can merge.
run_features() {  # base_name [--porcelain]
    local base_name="$1"
    shift
    local porcelain=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --porcelain) porcelain=1; shift ;;
            *) error "Usage: cs $base_name -features [--porcelain]" ;;
        esac
    done

    local features task record
    features=$(_worktree_features "$base_name")
    [ -n "$features" ] || return 0

    if [ -n "$porcelain" ]; then
        while IFS= read -r task; do
            [ -n "$task" ] || continue
            _feature_readiness "$base_name" "$task"
        done <<< "$features"
        return 0
    fi

    printf '%-24s %-24s %6s  %s\n' "FEATURE" "BRANCH" "AHEAD" "STATE"
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        record=$(_feature_readiness "$base_name" "$task")
        printf '%s\n' "$record" | awk -F'\t' \
            '{ detail = ($10 == "untracked") ? sprintf("%s file%s untracked", $7, ($7 == 1) ? "" : "s") : $10;
               printf "%-24s %-24s %6s  %s\n", $1, $2, $3, detail }'
    done <<< "$features"
}

# Ensure auto memory directory exists and migrate from default location
