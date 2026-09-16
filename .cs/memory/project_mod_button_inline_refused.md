---
name: mod-button-inline-refused
description: A mod Button nested in a Text is refused by the engine and the WHOLE band vanishes while the fake engine stays green; every new element goes to a --debug throwaway
metadata: 
  node_type: memory
  type: project
  originSessionId: a5912573-14ec-42d6-b3b1-66d25abdaa8d
  modified: 2026-09-16T14:30:46.439Z
---

Measured on Claude Code 2.1.273 (2026-09-16, the wrap key on cs-rotate): a
`<Button>` placed inside a `<Text>` makes the engine drop the hook's entire
`AbovePrompt` tree and draw its own. The only trace is one debug-log line,
`ui.render (AbovePrompt): a hook returned a tree that does not validate (Button
inside an inline element); drawing the engine's own`. The 60-test fake engine
in `mods/cs-rotate/test/` was green throughout: it validates no structure.

**Why:** a Button is a block element; Text is inline. The mod's tests assert on
the tree the hook returns, not on what the engine accepts, so a structural
refusal is invisible to them and the feature silently does not exist.

**How to apply:** keep separators and buttons as siblings inside the `Box`.
The rotate mod now pins `buttonsUnderText(tree) === 0` in every state; copy
that pin into any new mod. Before believing any new element or nesting, launch
a throwaway with `CLAUDE_CODE_BIN='~/.local/bin/claude --debug' cs <name>` and
grep `~/.claude/debug/<uuid>.txt` for `does not validate`. See
[[reference_mods_type_contract]] and [[prompthint-rewrite-draws-nothing]].
