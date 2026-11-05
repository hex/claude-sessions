# cs-mermaid

Draws Mermaid flowcharts in Claude Code replies. The
[`cs-mermaid` section in hooks.md](../../docs/hooks.md#cs-mermaid-not-a-hook-script--a-claude-code-mod)
describes setup, supported charts, colours, and the drawing option.

After a chart inside a list item, prose loses the indentation belonging to
the enclosing items. Their closing boundaries separate prose parts, so a
following numbered item starts a list when the engine reads it. List markers
stay in the text. Indentation belonging to code or a list opened after the
chart stays in place.
On a continuation that reaches the enclosing item's margin, `splitReply`
expands each tab to four spaces before removing the indentation, as marked does.

Run the checks from the repository root:

```sh
bash tests/test_mod_mermaid.sh && bash tests/test_mermaid_section.sh && bash tests/test_docs.sh
```

The engine test kit runs through `claude plugin test`. Fence and prose
comparisons use `marked.lexer(text)` from marked 15.0.12, installed outside
the checkout. After a change under `hooks/`, run `./build.sh` to update the
payload hashes in `install.sh`.
