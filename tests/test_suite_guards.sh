#!/usr/bin/env bash
# ABOUTME: Checks that shell tests are registered before their suite reports results.
# ABOUTME: Checks release tags against changelog headings and names each violation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

REPO="$SCRIPT_DIR/.."

# The harness counts multiline declarations; one-line declarations in these
# files belong to strings that generate fixture suites.
_check_suite_registrations() {  # files...
    awk '
        /^test_[A-Za-z0-9_]+\(\)[[:space:]]*\{[[:space:]]*$/ {
            name = $0
            sub(/\(\).*/, "", name)
            key = FILENAME SUBSEP name
            definitions[key] = FNR
            definition_order[++definition_count] = key
        }
        /^run_test[[:space:]]+/ {
            registered[FILENAME SUBSEP $2] = 1
            run_file[++run_count] = FILENAME
            run_name[run_count] = $2
            run_line[run_count] = FNR
        }
        /^report_results[[:space:]]*(#.*)?$/ {
            if (!(FILENAME in report_line)) report_line[FILENAME] = FNR
        }
        END {
            for (i = 1; i <= definition_count; i++) {
                key = definition_order[i]
                if (key in registered) continue
                split(key, parts, SUBSEP)
                printf "  FAIL: %s:%d: %s has no run_test registration\n", parts[1], definitions[key], parts[2]
                failed = 1
            }
            for (i = 1; i <= run_count; i++) {
                file = run_file[i]
                if (!(file in report_line)) {
                    printf "  FAIL: %s:%d: run_test %s has no report_results call\n", file, run_line[i], run_name[i]
                    failed = 1
                } else if (run_line[i] > report_line[file]) {
                    printf "  FAIL: %s:%d: run_test %s comes after report_results at line %d\n", file, run_line[i], run_name[i], report_line[file]
                    failed = 1
                }
            }
            exit failed
        }
    ' "$@"
}

test_every_test_function_is_registered_before_results() {
    _check_suite_registrations "$REPO"/tests/test_*.sh
}

_check_release_headings() {  # repo changelog
    local repo="$1" changelog="$2" tags="$TEST_TMPDIR/release-tags"
    if ! git -C "$repo" tag -l 'v*' > "$tags"; then
        echo "  FAIL: $repo: could not read release tags"
        return 1
    fi
    if [[ ! -s "$tags" ]]; then
        SKIP_REASON="checkout has no release tags (shallow checkout or tags not fetched)"
        echo "    SKIP: $SKIP_REASON"
        return 77
    fi

    # Releases write the topmost heading before creating its tag. Only that
    # heading may lack a tag; every tagged release still needs its heading.
    awk '
        FILENAME == ARGV[1] {
            version = substr($0, 2)
            tagged[version] = 1
            tag_order[++tag_count] = version
            next
        }
        /^## [0-9][^[:space:]]*[[:space:]]*$/ {
            version = $2
            headings[version] = 1
            heading_count++
            if (!(version in tagged) && heading_count > 1) {
                printf "  FAIL: %s:%d: heading ## %s has no release tag v%s\n", FILENAME, FNR, version, version
                failed = 1
            }
        }
        END {
            for (i = 1; i <= tag_count; i++) {
                version = tag_order[i]
                if (!(version in headings)) {
                    printf "  FAIL: %s: release tag v%s has no heading ## %s\n", ARGV[2], version, version
                    failed = 1
                }
            }
            exit failed
        }
    ' "$tags" "$changelog"
}

test_release_tags_match_changelog_headings() {
    _check_release_headings "$REPO" "$REPO/CHANGELOG.md"
}

run_test test_every_test_function_is_registered_before_results
run_test test_release_tags_match_changelog_headings

report_results
