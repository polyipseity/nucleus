---
description: "Use when adding or editing Home Manager activation scripts in Nix modules. Covers the promoted Style 3a pattern (replaceStrings + readFile), SCRIPT_DIR self-sourcing, and inline code prohibition."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix"
---

All activation scripts should converge on **Style 3a**:

```nix
# Preferred: with Nix-valued arguments
builtins.replaceStrings [tokens] [values] (builtins.readFile ./script.sh)

# Simpler: no Nix-valued arguments needed
builtins.readFile ./script.sh
```

## Rules

- **No inline shell code in Nix activation blocks.** Place all executable code in standalone `.sh` script files under `src/scripts/`. Nix activation blocks must only contain `builtins.readFile` and optionally `builtins.replaceStrings`.
- **No env vars as data-passing shim.** Never `export VAR="${expr}"` before `readFile`. Use `builtins.replaceStrings` with `__TOKEN__` placeholders instead.
- **Scripts must resolve dependencies relative to themselves via `SCRIPT_DIR`, never from `$REPO_ROOT`.** The SCRIPT_DIR pattern:
  ```bash
  SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
  ```
- **Small wrapper scripts are OK.** Creating a small activation script under `src/scripts/` that sources a library and calls its functions is preferred over inline code.

## Token naming convention

Use SCREAMING_SNAKE_CASE with double-underscore delimiters: `__TOKEN_NAME__`. Match the original env var name where possible (e.g., env var `WSS_SENTINEL` → token `__WSS_SENTINEL__`).

## Token-free scripts

If a script uses no Nix-valued data (all paths are hardcoded literals or derived from `$HOME` at runtime), use bare `builtins.readFile` with no `replaceStrings` wrapper.
