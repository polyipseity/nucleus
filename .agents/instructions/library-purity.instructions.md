---
description: "Use when enforcing or reviewing library purity in shell library scripts and PowerShell helper modules. Covers no-top-level-side-effects, no-build-time-inlining, no-token-substitution-in-libs, and function-parameter-only data flow."
name: "Library Purity"
applyTo: "src/scripts/lib/**, src/platforms/Windows/modules/scripts/**"
---

## Core rules

Library files (under `src/scripts/lib/`) are pure function/constant definitions. The same rules apply by analogy to Windows PowerShell helper modules under `src/platforms/Windows/modules/scripts/`.

1. **No top-level side effects on import.** A lib file must define functions and variables only — never execute commands at import time. No `set -eu` at the top level (only inside function bodies). No auto-invocation at end of file.

2. **No Nix placeholders.** Lib files must never contain `__TOKEN__`-style placeholders intended for Nix `builtins.replaceStrings`. All data must enter via function parameters.

3. **Nix must not `builtins.readFile` lib files.** Nix modules must source lib files at runtime (`. "$REPO_ROOT/src/scripts/lib/..."`) rather than inlining their content at build time.

4. **Data from Nix goes to the consumer script first, then to lib via function args.** The consumer (activation script, service script, or standalone Nix-derived script) receives data from Nix through its own parameters or token substitution, then passes it to lib functions as arguments.

## Exception

A lib file may be embedded via `builtins.readFile` when it contains a clean function definition (no tokens, no env var dependencies) and is being wrapped into a standalone script (e.g., a launchd daemon script) that will execute independently. The embedded lib must remain pure — all external inputs must arrive as function arguments from the wrapping code.
