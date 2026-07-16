# Secrets session prompt — design

Date: 2026-07-16
Status: pending spec review
Decision trail: Alex, 2026-07-16 — "when running cs secrets without a
session name it should ask for a session name". First of a three-feature
arc (secrets prompt → 60% context warning → /merge skill), approved
small-to-large. Approach A approved: numbered picker with a CWD-derived
default, over free-text entry (typo-created phantom keychain namespaces)
and silent CWD inference (a wrong silent guess against a secrets store).

## Context and goal

`bin/cs-secrets` resolves its target session as `CS_SECRETS_SESSION` →
`CLAUDE_SESSION_NAME` → `-s/--session`. Inside a cs-launched conversation
the env vars are always present; in a plain terminal none of them are, and
every session-scoped command dies with `No session specified. Set
CLAUDE_SESSION_NAME or use --session` (four guard sites: the main-path
guard and the three `age add|list|remove` guards). The goal: when that
guard trips on an interactive terminal, ask — list the sessions and read a
choice — instead of erroring. Headless behavior must not change.

## Decisions

1. **Picker, not free text.** The prompt lists existing sessions numbered;
   input is a number. Arbitrary names stay the job of `--session`, so a
   typo can never mint a phantom `cs:<typo>:*` keychain namespace.
2. **CWD-derived default.** When the working directory is inside a session
   under the sessions root, that session is the default and plain Enter
   accepts it. A worktree directory (`<base>@<task>`) defaults to `<base>`,
   matching the dispatch rule that worktree secrets live in the base
   session's namespace (`lib/99-main.sh`).
3. **stderr prompt, stdin read.** The list and prompt go to stderr; the
   choice is read from stdin. Command substitution captures only stdout,
   so `TOKEN=$(cs -secrets get X)` still works mid-prompt and the secret
   value stays clean. No `/dev/tty` dependency.
4. **Interactivity gate mirrors cs.** cs-secrets is standalone (cannot
   source `bin/cs`), so it replicates the two-line `cs_interactive()`
   predicate: `[[ -t 0 || "${CS_ASSUME_TTY:-}" == "1" ]]`. `CS_ASSUME_TTY`
   is the existing test override name; reusing it keeps one convention.
5. **Archived and worktree sessions are excluded from the list.** The
   sessions root holds dozens of directories; hiding `.cs/archived`
   sessions matches `cs -list`'s default and keeps the list scannable, and
   `<base>@<task>` dirs never own a secrets namespace. Both remain
   reachable via `--session` (or by standing in the directory: the CWD
   default is derived from the path, not from the list, so an archived
   session's own directory still defaults to it).
6. **One-shot, strict.** Empty input takes the default when one exists;
   any other input that is not a valid list number aborts with the
   existing error message, verbatim. No re-prompt loop: deterministic to
   test, and a confused paste never selects a session by accident.

## Behavior

New functions in `bin/cs-secrets`, called at all four guard sites:

```bash
secrets_interactive() {
    [[ -t 0 || "${CS_ASSUME_TTY:-}" == "1" ]]
}

# Sets SESSION_NAME from an interactive picker, or leaves it empty.
prompt_session_choice() { ... }

require_session() {
    if [[ -z "$SESSION_NAME" ]] && secrets_interactive; then
        prompt_session_choice
    fi
    if [[ -z "$SESSION_NAME" ]]; then
        error "No session specified. Set CLAUDE_SESSION_NAME or use --session"
    fi
}
```

Guard-site replacement (all four keep their surrounding conditions):

- `age add` / `age list` / `age remove`: the
  `[[ -z "$SESSION_NAME" ]] && error ...` line becomes `require_session`.
- Main path: `if [[ -z "$SESSION_NAME" && -n "$COMMAND" ]]; then error ...`
  becomes `if [[ -n "$COMMAND" ]]; then require_session; fi` — commands
  that never had a session guard (`age init`, `age pubkey`, `--help`) are
  untouched.

`require_session` uses if-form, not `&&` chains: cs-secrets runs under
`set -e`-style discipline and a failed `&&` tail as a function's last
command would propagate a spurious nonzero (the command-substitution-traps
lesson: prompts live in a directly-called function that sets a global,
never in `$(...)`).

`prompt_session_choice`:

1. Enumerate `"$sessions_root"/*/` (glob order = sorted, bash 3.2 safe)
   where `sessions_root="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"`.
   Keep directories that contain `.cs/`; skip names containing `@`; skip
   those with `.cs/archived`. Zero survivors → return with `SESSION_NAME`
   empty (caller errors as today).
2. Derive the default: `pwd -P` compared against the resolved sessions
   root; if inside it, the first path component below the root, with any
   `@<task>` suffix stripped. The derived name must contain a `.cs/`
   directory to qualify; archived is allowed.
3. Print to stderr: a header line, the numbered list, then the prompt —
   `Session number [<default>]: ` with a default, `Session number: `
   without.
4. `read -r` from stdin. Empty + default → default. A number `1..N` →
   that entry. Anything else (including empty without default, `q`, EOF)
   → return with `SESSION_NAME` empty.

Prompt copy (frozen for tests):

```
No session specified. Pick one:
  1) apollo
  2) claude-sessions
Session number [claude-sessions]:
```

## Out of scope

- cs dispatch (`lib/80-secrets.sh`, `lib/99-main.sh`) is untouched — the
  env-var and `--session` paths already work.
- Free-text session entry, re-prompt loops, filtering to sessions that
  have secrets, recency sorting.
- Any change to headless/non-interactive behavior or to the error string.

## Testing

New cases in `tests/test_cs_secrets.sh` (existing harness: isolated
`CS_SESSIONS_ROOT`, encrypted backend, fake `HOME`; its `setup()` exports
`CLAUDE_SESSION_NAME=test-session`, so prompt tests unset it for their
invocations and create fake sessions as `mkdir -p
"$CS_SESSIONS_ROOT/<name>/.cs"`). The suite runs on stock bash 3.2; every
assert carries `|| return 1`; new cases insert above `report_results`.

1. Headless unchanged: no TTY, no `CS_ASSUME_TTY`, no session env →
   `list` fails with the verbatim existing error.
2. Picker selects: `CS_ASSUME_TTY=1`, two fake sessions, stdin `2` →
   command targets the second alphabetical session (observable via
   `list` output naming the session).
3. stdout stays clean: in the same invocation, assert the prompt/list
   text appears on stderr and stdout carries no picker text (the
   command-substitution property).
4. Enter takes CWD default: run from inside a fake session dir, stdin
   empty line → resolves to that session.
5. Worktree maps to base: run from inside `<base>@<task>` dir → default
   is `<base>`; and `<base>@<task>` never appears in the list.
6. Archived hidden but CWD-defaultable: archived session absent from the
   list; running from inside it still defaults to it.
7. Strict abort: out-of-range number → verbatim existing error; empty
   input with no default → verbatim existing error.
8. No sessions under root → verbatim existing error even with
   `CS_ASSUME_TTY=1`.

## Files

- `bin/cs-secrets` — the three new functions, four guard-site edits, a
  `usage()` note under `-s, --session` ("interactive terminals are
  offered a session picker"), and `CS_ASSUME_TTY` in the ENVIRONMENT
  section.
- `tests/test_cs_secrets.sh` — the eight cases above.
- `docs/secrets.md` — a short "No session name?" paragraph.
- `README.md` — one line in the secrets section.

Deploy surface: `~/.local/bin/cs-secrets` (standalone; not generated by
`build.sh`).
