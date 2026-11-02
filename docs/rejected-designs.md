# Rejected designs

This page lists the designs cs rejected or declined, so nobody proposes them again, and a row leaves only with new evidence.

## Session names and storage

| Rejected | Reason | Date |
|---|---|---|
| Renaming the on-disk `@` separator so that peers can message a feature session | A rename touches existing directories, typed names, docs, and the TUI, and both spellings would need parsing forever, so cs [maps the name](commands.md#parallel-worktrees) at `claude --name` only. | 2026-11-02 |
| A reserved token such as `--` in place of `+` for `claude --name` | `--` is legal in a plain session name, so the mapped name can collide with a real session. | 2026-11-02 |
| `CLAUDE_SESSION_NAME` set to the `+` form | The `cs-panel` mod does not accept `+` in that variable. | 2026-11-02 |
| Archiving a session by moving its directory | Claude Code keys transcripts on the working directory, so a moved session cannot resume its conversation. | 2026-07-15 |
| Session-end auto-commit, git-sync verbs, and SSH remote sessions | All three were unused, and the auto-commit once put a user's real code on a feature branch of an adopted repo. | 2026-06-24 (v2026.6.9) |

## Platforms and runtimes

| Rejected | Reason | Date |
|---|---|---|
| The mods design lab inside cs | The lab grew to about 11k lines in `docs/` and became its own project, and cs keeps only the exported draw functions and line tables. | 2026-10-25 |
| CodeHero and infaiw as a base for running cs as a server | `claude remote-control` already covers server-owned sessions and remote approvals, and a second read of either repo costs a day. | 2026-09-14 |
| Routing cs through an `ANTHROPIC_BASE_URL` gateway | Claude Code sends the subscription OAuth token to a custom base URL, and the rewriter child of cs keeps that variable, so the gateway would receive the credential from cs itself. | 2026-09-06 |
| Windows and Git Bash support | The Claude launch and the tmux spawner never ran under Git Bash, so the tier shipped a session directory and a "use WSL" message, and WSL2 runs cs like any other Linux. | 2026-08-08 |
| Rewriting `cs-tui` in TypeScript with OpenTUI on bun | `bun build --compile` has a floor of about 58 MB against about 1 MB for the Rust binary, and the lag that prompted the idea came from a git subprocess in the draw call. | 2026-07-10 |
| Rewriting `cs-tui` in Python with Textual | Every Python distribution route gives up a start under 10 ms and the single binary, which are part of what `cs-tui` promises. | 2026-07-02 |

## Features and maintenance

| Rejected | Reason | Date |
|---|---|---|
| A `cs -doctor` version warning for a deployed file kept from another checkout | `_cs_owns_file` checks against every shipped hash, so it misses only a build from another branch, and that gap reaches only people who develop cs. | 2026-11-02 |
| A keyword-scored band that suggests a diagram | A short prompt section with an off switch lets the model decide with full context, and a keyword band is noisy and adds a new element on screen. | 2026-10-18 |
| An append-only `PreToolUse` guard on `Write` and `Edit` for narrative files | Across 4327 transcripts, narrative files took 2 `Write` calls and 0 `Edit` calls, because appends go through Bash, which such a guard never matches. | 2026-09-28 |
| A new advertised `cs` verb for a capability | Every capability ships as a skill, hook, plugin command, or automatic behavior, and a verb exists only as hidden plumbing behind one. | 2026-09-14 |
| Driving or ending a peer Claude session from cs with `tmux send-keys`, a signal, or a deferred kill marker | Anything cs injects races the running session's directory, composer, and final writes, so cs refuses with a message that names the session to close. | 2026-09-14 |
| A per-project corpus exclusion for `/write-as-me`, such as `CS_VOICE_EXCLUDE` or `.voiceignore` | Filtering stays a manual step, and the profile's `## Provenance` section records each exclusion so the next rebuild repeats it. | 2026-08-10 |
| A usage count of `cs` verbs | A count covers Claude's Bash calls and not the verbs a person types, so cs judges a verb by the skills, hooks, and prompt injections that call it. | 2026-07-19 |
| Deleting phases from `lib/45-migrate.sh` | Each phase guards a one-time layout transition and an old session can resume at any later release, so a deleted phase strands that session's logs and discoveries. | 2026-07-19 |
