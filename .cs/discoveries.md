# Discoveries & Notes

## Zsh completion fpath mismatch (FIXED in v2026.2.9)

- The `cs` installer previously hardcoded `~/.zsh/completions` but users may have `~/.zsh/completion` (singular) in their fpath
- Fixed: installer now detects existing fpath config from `.zshrc` and installs to the matching directory

## Completion files listed wrong sync subcommand (FIXED in v2026.2.9)

- Both `completions/cs.bash` and `completions/_cs` listed `init` as a sync subcommand
- The actual subcommand is `remote` — fixed in both files

## Doc review findings (FIXED in v2026.2.9)

- sync.md had wrong emoji (🤖 vs actual 🔄/📝/📦/📋), wrong commit formats, missing clone [name] param
- hooks.md had wrong hook count, inaccurate discovery-commits description, wrong secret export precondition

## Age encryption not wired into sync flows (pre-existing bug)

- `sync_status` only checks for `secrets.enc`, reports "not exported" even when `secrets.age` exists
- `sync_clone` only imports `secrets.enc`, silently skips `secrets.age`
- `sync_push` only exports when `CS_SECRETS_PASSWORD` is set, never triggers for age encryption
- Age is documented as the recommended approach but these three sync functions don't support it

## Duplicate discovery-commits.sh hook in settings.json

- `discovery-commits.sh` is registered twice in PostToolUse (once with tilde path, once with absolute path)
- This likely causes double commits on discovery file writes
