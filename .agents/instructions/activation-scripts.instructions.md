---
description: "Use when adding or editing Home Manager activation scripts in Nix modules. Covers the direct-inline pattern (readFile library + inline call), replaceStrings for standalone scripts, and when to keep vs eliminate wrapper scripts."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix"
---

## Canonical pattern: direct-inline

For library-backed activation blocks, read the library directly and call its functions inline:

```nix
activation-block = lib.hm.dag.entry<Phase> [ "dependency" ] ''
  ${builtins.readFile ../scripts/lib/some-lib.sh}
  some_function ${lib.escapeShellArg arg1} "${arg2}" ${toString arg3}
'';
```

Rules:

1. **Read the library only.** Never read a wrapper — always read the canonical lib under `src/scripts/lib/`.
2. **Keep calls minimal.** One or two lines per function call. For complex logic (loops, conditionals, file ops), keep a standalone script.
3. **No shebang.** Activation blocks are sourced fragments inside `set -eu` shell; do not add `#!/usr/bin/env bash`.
4. **No SCRIPT_DIR / `.` sourcing.** Library functions are embedded directly via `builtins.readFile`.
5. **`lib.escapeShellArg` for Nix values** going into shell single-quoted context. Use double quotes for simple store paths (`"${pkgs.jq}/bin/jq"`).
6. **`$HOME` preserved.** In Nix `''` strings, `$` passes literally unless followed by `{`. `$HOME` works at runtime.

## Standalone scripts (for complex logic)

When a script has substantive logic beyond sourcing + calling (loops, conditionals, file operations, error handling), keep it as a standalone `.sh` under `src/scripts/` and embed it with bare `readFile` (or `replaceStrings` for Nix-valued data):

```nix
# Preferred: with Nix-valued arguments via replaceStrings
builtins.replaceStrings [tokens] [values] (builtins.readFile ./script.sh)

# Simpler: no Nix-valued arguments needed
builtins.readFile ./script.sh
```

Standalone scripts are also required when:
- Shebang needed (launchd agents, cron jobs, direct execution)
- Used outside activation blocks (e.g., launchd `ProgramArguments`)
- Sources a lib AND has substantive logic beyond the function call

## What to eliminate: pure wrapper scripts

A script that only sources a library and calls its functions should be **eliminated** — inline the library read and function call directly in the activation block. Qualifying traits:

1. Sets `SCRIPT_DIR`, sources a library via relative path
2. Calls one or more functions from that library with token arguments
3. Has NO own conditional logic, loops, file operations, or other substantive shell code
4. Has NO shebang line (unless the shebang is the only guard and the script is otherwise trivial)

**Exception:** Trivial conditionals (e.g., a single `[ -x ]` guard) may be inlined rather than kept as a script.

## Token naming convention (for standalone scripts)

Use SCREAMING_SNAKE_CASE with double-underscore delimiters: `__TOKEN_NAME__`. Match the original env var name where possible (e.g., env var `WSS_SENTINEL` → token `__WSS_SENTINEL__`).

## No env vars as data-passing shim

Never `export VAR="${expr}"` before `readFile`. Use `builtins.replaceStrings` with `__TOKEN__` placeholders instead.

## Scripts must resolve dependencies relative to themselves via `SCRIPT_DIR`

Never reference `$REPO_ROOT` at runtime. The SCRIPT_DIR pattern:

```bash
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
```

This rule does not apply to scripts that are inlined via `builtins.readFile` — they use no `SCRIPT_DIR` at all.
