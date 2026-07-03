# Task queue — follow-ups

Non-blocking items deferred from the task-queue feature (branch `wip/task-queue`,
merged 2026-07-03). None is a data-loss, hang, or security defect — the whole-branch
review (opus) rated the feature Ready to Merge with every item below triaged to
follow-up. Grouped by area; each is independently shippable.

## A. Robustness hardening (bin/cs + hooks/narrative-reminder.sh)

1. **Phantom session dir from `cs <nonexistent> -queue add`.** The session-scoped
   dispatch arm (bin/cs, the `-queue)` case near the `-secrets` arm) resolves the
   target from the name and `mkdir -p`s `$SESSIONS_ROOT/<name>/.cs/local/`, so a
   typo'd session name silently materializes a skeleton the TUI may render as a
   phantom row. The `-secrets` arm it was copied from doesn't create a dir. Fix:
   guard the arm with `[ -d "$SESSIONS_ROOT/$session_name" ] || error "no such
   session: $session_name"` before calling `run_queue`. Add a test: `cs <missing>
   -queue add "x"` exits non-zero and creates nothing.

2. **`_queue_rm` accepts `0` and out-of-range indices as silent no-ops.** The
   `''|*[!0-9]*` guard rejects non-numeric but lets `0`/`99` reach an awk that
   matches nothing, so `cs -queue rm 99` succeeds silently. Fix: count non-blank
   lines first; if `n < 1 || n > count`, `error` with the valid range. Add tests
   for `rm 0` and `rm <past-end>`.

3. **Gate has no fire-cooldown.** Unlike the narrative nag (which stamps a 5-min
   cooldown whenever it fires), the queue gate writes `queue.declined` only when the
   agent runs `cs -queue defer`. If the agent ever stops at the gate without
   asking/deferring, the gate re-`block`s on every stop until it does. This matches
   the spec's "re-ask until answered" intent and `stop_hook_active` is the platform
   backstop, so it self-resolves in one round — but if disruption is observed,
   add a short fire-cooldown (e.g. stamp a `queue.gate-shown` marker with a 60s TTL).

4. **add-vs-pop lost-update race.** The drain's pop is read-all-but-first →
   `>tmp` → `mv`; a concurrent `cs -queue add` (`>>`) landing between the awk read
   and the `mv` is clobbered. Sub-second window, only at a stop boundary; the
   dropped-task consequence is the same class trust-and-pop already tolerates, and
   the spec's atomicity guarantee only claimed add-vs-add. Fix if it ever bites:
   serialize pop and add under a lock (e.g. `mkdir` lock on `.cs/local/queue.lock`),
   or have the drain re-read after `mv` and reconcile.

5. **Pop-failure path leaves a stale `QSTATE=draining` shell var.** On a failed pop
   (very rare) the drain disarms to `idle` and falls through to the narrative logic
   instead of emitting an explicit approve (narrative-reminder.sh, the pop `else`
   branch). Harmless (the no-re-inject safety property holds, next stop re-gates),
   but a one-line `echo '{"decision":"approve"}'; exit 0` after disarming is tidier.

6. **`_pctdir` unscoped global inside `_parse_stdin` (bin/cs-statusline).** Cosmetic
   in a short-lived render process; add `local _pctdir` opportunistically if
   `_parse_stdin` is refactored.

## B. Test coverage gaps

7. **No render-level assertion for the `[Nq]` badge.** Only `scan_counts_queue_depth`
   (session.rs) covers the depth count; nothing asserts the badge span actually
   renders in `ui.rs` when `queue_depth > 0` (the secrets gutter icon has such a
   test). Add a buffer-render test.

8. **Spec edge cases only implicitly covered by the bash drain tests:** mid-drain
   add (task appended during `draining` drains after current items), runaway/pop-
   failure disarm, and the explicit "narrative nag yields while a drain is armed"
   case. The armed/draining tests exercise these paths only indirectly — add direct
   tests to `tests/test_queue.sh`.

## Notes

- All queue state is machine-local (`.cs/local/`, gitignored); none of these items
  affect the multi-user/worktree partition, which the whole-branch review confirmed
  clean (the worktree fuse never touches `.cs/local/`).
- The feature shipped injection-safe: every drain reason emits via `jq -nc --arg`,
  so nothing here concerns the safety of injected task text.
