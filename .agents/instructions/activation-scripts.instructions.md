---
description: "Use when adding or editing activation scripts in Nix modules. Covers the activation bundle architecture, inline activation rules, standalone script patterns (for launchd/systemd), prohibited patterns, and conventions."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh"
---

All activation blocks in this repo must use the **activation bundle subprocess pattern**: scripts live in `src/scripts/`, are assembled into a single Nix derivation (`src/modules/lib/activation-bundle.nix`), and are invoked as subprocesses from activation blocks.

This eliminates `builtins.readFile` embedding, `__TOKEN__` placeholders, and `+` concatenation from activation blocks entirely.

---

## Activation bundle architecture

`src/modules/lib/activation-bundle.nix` builds a `nucleus-activation-bundle` derivation containing `$out/bin/` (executable scripts) and `$out/lib/` (shared libraries). Every script in `bin/`:

1. Sets `SCRIPT_DIR` from `$0`
2. Sources libs via `"$SCRIPT_DIR/../lib/<name>.sh"`
3. Accepts per-user values as CLI positional args
4. Executes as a standalone subprocess

**Adding a new script to the bundle:**

1. Create the script in `src/scripts/` (cross-platform) or `src/scripts/hosts/<Host>/` (host-specific).
2. Follow the SCRIPT_DIR + lib sourcing pattern (see below).
3. Register it in `activation-bundle.nix` under `p.bin.<name>`.
4. Invoke from Nix as `"${activationBundle}/bin/<name>" <pos-arg1> <pos-arg2>`.

---

## Activation block invocation

Every activation block must invoke a bundle script as a subprocess. The Nix expression provides per-user values as positional CLI args.

```nix
# Shared activation bundle path (define in `let` block or inherit from imports)
activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };

# Simple inline: pure inline, ≤3 lines, no deps (the ONLY exception to subprocess)
home.activation.provisionDevDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  mkdir -p "$HOME/dev"
'';

# Standard: subprocess invocation with Nix-valued args
home.activation.some-step = lib.hm.dag.entryAfter [ "dependency" ] ''
  "${activationBundle}/bin/script-name" \
    "${pkgs.tool}/bin/tool" \
    '${builtins.toJSON nixValue}'
'';

# Thin wrapper: managed-symlink (protect/unprotect a single path)
home.activation.protectFoo = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/bin/managed-symlink" "protect" "moduleName" "$HOME/.config/foo"
'';

# Out-of-store symlinks bulk: manage-out-of-store-symlinks
home.activation.protectOutOfStoreSymlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/bin/manage-out-of-store-symlinks" "protect" "home.nix" '${builtins.toJSON paths}' "${pkgs.jq}/bin/jq"
'';
```

Rules:

- **Always use `activationBundle` from `pkgs.callPackage ./lib/activation-bundle.nix { }`** — never hardcode a store path.
- **Use `"${activationBundle}/bin/<name>"`** — the leading `"` makes Nix expand the store path.
- **Positional CLI args for all per-user values.** No `__TOKEN__` placeholders.
- **Use `lib.escapeShellArg` for values going into shell single-quoted context** (prevents injection).
- **Use `builtins.toJSON` for structured data** (lists, attrsets) and pass as a single quoted argument.
- **Use double quotes for store paths** (`"${pkgs.jq}/bin/jq"`).
- **`$HOME` is preserved** in Nix `''` strings (`$` passes literally unless followed by `{`).

### Pure inline exception

≤3 lines, no conditional logic, no loops, no external tool dependencies. Write directly as a string literal in the activation block. This is the **only** exception to the subprocess rule — anything more complex must be a bundle script.

```nix
home.activation.foo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  mkdir -p "$HOME/some-dir"
'';
```

---

## Script conventions (bundle scripts under `src/scripts/`)

Every standalone script must source libs via SCRIPT_DIR and accept CLI positional args:

```bash
# shellcheck shell=sh
# <description of what this script does>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"

_arg1="$1"
_arg2="$2"
```

Rules:

- **Always start with `set -euo pipefail`** (except scripts that intentionally allow failures).
- **Always define `SCRIPT_DIR`** — never reference `$REPO_ROOT` at runtime.
- **Source libs via SCRIPT_DIR-relative path.** Never use `${repoRoot}` or hardcoded paths.
- **Use descriptive variable names** with a script-specific prefix (e.g., `_mqi_` for merge-qtpass-ini).
- **Do not define functions as `main()`** — scripts are standalone executables, run top-to-bottom.
- **No Nix `__TOKEN__` placeholders** — all per-user values come as CLI positional args.
- **No shebang in activation bundle scripts** — the bundle derivation sets bash as the interpreter.

---

## Standalone scripts for launchd/systemd (NOT activation blocks)

For launchd agents, systemd services, cron jobs, or any other consumer that needs an **executable store path**, use `pkgs.writeShellScript` (or `writeTextFile` if a specific shebang is needed):

```nix
someScript = pkgs.writeShellScript "script-name" ''
  #!${pkgs.bash}/bin/bash
  set -eu
  ${builtins.readFile ../scripts/lib/some-lib.sh}
  some_function "${arg}"
'';
```

These are NOT activation blocks — they are standalone executables deployed via launchd/systemd. They may use `builtins.readFile` + `builtins.replaceStrings` for token substitution, and must follow the **string interpolation, not concatenation** rule below.

---

## String interpolation, not concatenation

In all Nix expressions that produce script bodies (activation blocks, `pkgs.writeShellScript`, `pkgs.writeTextFile.text`, etc.), always use `${...}` string interpolation rather than `+` string concatenation.

**Correct (interpolation):**

```nix
text = ''
  ${builtins.readFile ./lib.sh}
  some_function "${arg}"
'';
```

**Incorrect (concatenation):**

```nix
text = ''
  #!${bash}/bin/bash
  set -eu
''
+ builtins.readFile ./lib.sh
+ ''
  some_function "${arg}"
'';
```

---

## Prohibited patterns

- **No `builtins.readFile` in activation block bodies.** The ONLY exception is the pure inline pattern (≤3 lines, no deps) which contains NO readFile call.
- **No `builtins.replaceStrings` in activation blocks.** Use CLI positional args instead.
- **No string concatenation (`+ ''...''` or `) + builtins.readFile ...)` in any script-producing expression** — use `${...}` interpolation.
- **No `__TOKEN__` placeholders in bundle scripts.** All per-user values are CLI positional args.
- **No wrapper scripts that only source a lib and call functions** — use `managed-symlink` or `manage-out-of-store-symlinks` instead.
- **No inline Python invocation in activation blocks** — wrap in a bundle script.
- **No env vars as data-passing shim** — use CLI args.
- **No `$REPO_ROOT` runtime references** in bundle scripts — use `SCRIPT_DIR` instead.
- **No outer string wrapping a script invocation** — the invocation string is the activation body directly.

### Exception documentation

Every exception to these rules must have an inline `# WHY` comment in the Nix expression explaining the technical constraint that prevents using the standard pattern.
