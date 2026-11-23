# Review guide for cs

Read this before you review a cs change. It lists what counts as a defect in cs and how to report one. Each item is a bug cs has shipped or nearly shipped.

## Defects to look for

cs runs under `set -euo pipefail`, on bash 3.2 and on BSD as well as GNU userland. Most of its bugs fail without a message.

- A swallowed error: `|| true`, `|| x=""` or `2>/dev/null` on a step whose result matters, or a dispatch `case` with no `*)` arm, which does nothing for an unknown value.
- A function that a caller captures with `$(...)` and that warns to stdout or exits. The warning corrupts the captured value, and `exit` leaves only the subshell, so the caller goes on with an empty value.
- A jq pass trusted by its exit status. A runtime error on any record but the last goes to stderr, jq exits 0, and the output has a hole.
- A reader that exits early behind a pipe, such as `producer | grep -q` or `| head`. Past 64 KB the producer gets `SIGPIPE`, pipefail returns 141, and cs dies without a message. BSD tools often hide this on a Mac.
- An awk program with `exit N` in its body and an `END` block. `END` still runs and its exit status wins.
- A function whose last statement is `[ cond ] && cmd`. It returns 1 on the false branch, and `set -e` aborts any caller that runs it as a bare statement.
- A step that relies on errexit inside a function called from `if`, `&&` or `||`. Bash turns errexit off for the whole body, so a failed `x=$(...)` lets the function return 0.
- Bash 4 and GNU-only code: `local -A`, `declare -A`, `mapfile`, `readarray`, `${v^^}`, `${v,,}`, `local -n`, `@Q`, `printf '%(...)T'`, `$EPOCHREALTIME`, fractional `read -t`, `\+` or `\?` in sed or awk, `sed -i`, `mktemp -t`, and `stat` with one platform's flags and no fallback. Hooks and the statusline run under `/bin/bash` 3.2 even when a newer bash leads `PATH`.
- A test whose fixture builds a different path or state than the one the code probes. The assert cannot fail, so the suite stays green on broken code.
- A test that asserts conditional output and does not stage the condition. When the output depends on a binary on `PATH`, an env var or a key, the test must set that up itself, or it passes on one machine and fails on another.
- An `assert_*` call without `|| return 1`. `run_test` calls each test as `"$test_name" || status=$?`, so errexit is off and a failed assert in the middle of a test prints `FAIL` while the test passes.
- A new code path where cs commits or runs `git add` on files under `.cs/`. A session directory can be a user's own repository. The only git writes cs makes are the commit that creates a session, the `-finish` merge commit and the autosave shadow ref.
- A new file write inside a session directory that is not classified for multi-user use. Per-machine values go in the untracked `.cs/local/`, append-only logs get `merge=union` in `setup_merge_attributes`, and a date in a tracked file comes from git history, never from the local clock.
- A validation that checks the input and not the output of a transform. The name `path` passes an identifier check, and upper-casing turns it into `PATH`.

## How to review

- Assert the property, not "no crash". Exit 0 and valid JSON do not show that a row fits its width or that its text is right, so measure the output.
- Name every consumer of a changed function, flag, env var, file format or printed output, and read each one by path. Callers depend on observable behaviour, documented or not.
- Review the code that a change newly makes reachable, not only the diff. A wider lookup or an earlier call can expose old lines, and "pre-existing" is no reason to skip them.
- Back each finding with file:line and the input that breaks it. A finding without a reproduction is a hypothesis, so say so in the finding.

## What to skip

- Generated files. `build.sh` writes `bin/cs`, `hooks/cs-shared.sh`, `hooks/cs-config.sh` and `install.sh` from `lib/` and `install.sh.in`, and splices `lib/03-config.sh` into a marked block of `bin/cs-statusline`. Review the sources. The CI `build-sync` job checks that the generated files match them.
- Style-only remarks on formatting, naming taste or wording.

## Output

Start with the number of findings, then list them with the most severe first. Give each finding one label:

- `important` marks a defect the change brings in that a user or a test run would hit.
- `pre-existing` marks a defect that was there before the change.
- `nit` marks a real defect with a small effect.
