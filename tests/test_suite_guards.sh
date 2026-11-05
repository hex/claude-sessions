#!/usr/bin/env bash
# ABOUTME: Checks that shell tests are registered before their suite reports results.
# ABOUTME: Names each offending file and function in a failed check.

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

run_test test_every_test_function_is_registered_before_results

report_results
