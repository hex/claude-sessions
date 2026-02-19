# Discoveries & Notes

## Zsh completion not working — fpath mismatch

- The `cs` installer puts the zsh completion file at `~/.zsh/completions/_cs` (plural)
- Alex's `.zshrc` line 216 has `fpath=(~/.zsh/completion $fpath)` (singular, missing 's')
- This means `compinit` never discovers the `_cs` completion function
- Fix: either update `.zshrc` to use `completions` (plural), or have the installer match the existing fpath directory
