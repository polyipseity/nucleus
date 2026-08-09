---
description: "Use when adding, renaming, or reviewing activation entries, or adding or editing activation scripts in Nix modules. Covers naming conventions, the activation bundle architecture, inline activation rules, standalone script patterns (for launchd/systemd), prohibited patterns, and conventions."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh, src/modules/terminal-activations.nix, src/hosts/Windows/apply.ps1, src/platforms/Windows/modules/system/Sync-TerminalActivation.ps1"
---

# Activation scripts and naming

## Naming conventions

All activation entry names — `home.activation.*`, `system.activationScripts.*`, and `nucleus.terminalActivations.*` — follow these rules:

- **kebab-case only.** Use hyphens to separate words: `cloud-drives-setup`, not `cloudDrivesSetup` or `cloud_drives_setup`.
- **verb-first.** Start every name with a verb or action word: `provision-dev-repos`, `install-pwsh-yaml`, `merge-obsidian-json`.
- **Host-prefixed when OS-specific.** If the activation only applies to one OS, prefix with `macos-` or `nixos-`:
  - `macos-configure-finder-sidebar`, `nixos-launch-nvim`
- **No prefix when cross-platform.** If the activation applies to multiple operating systems, no host prefix:
  - `cloud-drives-setup`, `provision-dev-repos`, `wait-for-sops-secrets`
- **No `nucleus-` prefix.** The project name is redundant — all activations in this repo are nucleus-specific.
- **Keep `protect`/`unprotect` for symlink hardening.** The shared protect/unprotect pattern in `home.nix` uses `protect-out-of-store-symlinks` / `unprotect-out-of-store-symlinks`. Generated entries from `config-utils.nix` use the underscored `unprotectSymlink_${name}` / `protectSymlink_${name}` / `mergeConfig_${name}` pattern — these are exempt.

### Exempt classes

The following activation entry types are **not** subject to the naming policy:

1. **Generated names** from `config-utils.nix`: `unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*` — these are dynamically generated from data, not manually authored.
2. **Built-in Home Manager phases**: `linkGeneration`, `writeBoundary`, `checkLinkTargets`, `setupLaunchAgents`, `installPackages` — these are framework-defined.
3. **`sops-nix` entries**: framework-defined names.
4. **nix-darwin system activationScripts**: only the hardcoded names (`extraActivation`, `postActivation`, `preActivation`) work; custom names are silently ignored.

### DAG ordering references

When referencing another activation in `entryAfter [...]` or `entryBefore [...]`, use the exact kebab-case name of the target entry. For built-in phases, use the framework-provided name (e.g., `"linkGeneration"`, `"writeBoundary"`).

Shared DAG dependency names are defined in `src/modules/lib/activation-dag.nix`.

### References in documentation and comments

All references to activation entry names in documentation, code comments, echo messages, script header comments, and any other human-readable text must use the same kebab-case verb-first naming convention. Stale camelCase references to renamed activations must be updated alongside the rename.

---

All activation blocks in this repo must use the **activation bundle subprocess pattern**: scripts live in `src/scripts/`, are assembled into a single Nix derivation (`src/modules/lib/script-tree.nix`), and are invoked as subprocesses from activation blocks.

This eliminates `builtins.readFile` embedding, `__TOKEN__` placeholders, and `+` concatenation from activation blocks entirely.

---

## Activation bundle architecture

`src/modules/lib/script-tree.nix` builds a `nucleus-script-tree` derivation containing all scripts from `src/scripts/` bundled into `$out/src/scripts/` with the same subtree structure, making `$out/` the repo root.

Every script in the bundle:

1. Sets `SCRIPT_DIR` from `$0`
2. Sources libs via `"$SCRIPT_DIR/../lib/<name>.sh"`
3. Accepts per-user values as CLI positional args
4. Executes as a standalone subprocess

**Adding a new script to the bundle:**

1. Create the script in `src/scripts/` (cross-platform), `src/platforms/<Platform>/scripts/` (platform-specific), or `src/hosts/<Host>/scripts/` (host-only).
2. Follow the SCRIPT_DIR + lib sourcing pattern (see below).
3. It is automatically included — no manual registration needed.
4. Invoke from Nix as `"${activationBundle}/src/scripts/<path>.sh" <pos-arg1> <pos-arg2>`.

---

## Activation block invocation

Every activation block must invoke a bundle script as a subprocess. The Nix expression provides per-user values as positional CLI args.

```nix
# Shared activation bundle path (define in `let` block or inherit from imports)
activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

# Simple inline: pure inline, ≤3 lines, no deps (the ONLY exception to subprocess)
home.activation.ensure-dev-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  mkdir -p "$HOME/dev"
'';

# Standard: subprocess invocation with Nix-valued args
home.activation.some-step = lib.hm.dag.entryAfter [ "dependency" ] ''
  "${activationBundle}/src/scripts/configs/script-name.sh" \
    "${pkgs.tool}/bin/tool" \
    '${builtins.toJSON nixValue}'
'';

# Thin wrapper: managed-symlink (protect/unprotect a single path)
home.activation.protectFoo = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "moduleName" "$HOME/.config/foo"
'';

# Out-of-store symlinks bulk: manage-out-of-store-symlinks
home.activation.protect-out-of-store-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "protect" "home.nix" '${builtins.toJSON paths}' "${pkgs.jq}/bin/jq"
'';
```

Rules:

- **Always use `activationBundle` from `pkgs.callPackage ./lib/script-tree.nix { }`** — never hardcode a store path.
- **Use `"${activationBundle}/src/scripts/<path>.sh"`** — the leading `"` makes Nix expand the store path.
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
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

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

Every exception to these rules must have an inline `# WHY:` comment in the Nix expression explaining the technical constraint that prevents using the standard pattern.

## Terminal activations (last resort)

Terminal activations (`nucleus.terminalActivations`) are a **LAST RESORT**. Never add a new entry unless **all three** criteria are met:

1. **TCC constraint**: the command MUST run in the user's terminal context (outside sudo/Nix activation) — typically because macOS TCC grants (Full Disk Access, Accessibility) are required and would be lost inside the sudo process tree during `darwin-rebuild switch`.
2. **No alternative**: the command cannot be refactored into a Nix declarative option, a Home Manager activation entry, or a system activation script that runs inside the rebuild.
3. **Documented constraint**: the technical constraint is documented inline with a `# WHY: terminal-activations (last resort):` comment at the call site.

If a command does not need TCC-sensitive context (FDA, Accessibility, Screen Recording, Automation), it **SHOULD** run as a normal Nix/Home Manager activation entry. Terminal activations are inherently imperative (eval'd from a manifest file) and bypass the declarative Nix model — each use erodes reproducibility.

Every `nucleus.terminalActivations` entry in `.nix` files must have a `# WHY: terminal-activations (last resort):` comment immediately before it, explaining why the Nix activation path cannot work for that specific command.

macOS `darwin-rebuild switch` runs as root (via sudo). Activation scripts executing inside that process tree lose macOS TCC grants. Terminal activations escape the sudo process tree, so TCC grants are inherited from the user's shell session. On Linux and Windows there is no TCC concept — if a terminal activation is added for a non-macOS host, it must have an equally compelling reason documented.

See `src/modules/terminal-activations.nix` for the canonical module definition and policy text.
