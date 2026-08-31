---
description: "Use when adding, renaming, or reviewing activation entries, or adding or editing activation scripts in Nix modules. Covers naming conventions, activation bundle architecture, inline activation rules, standalone script patterns, prohibited patterns, and conventions."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh, src/modules/terminal-activations.nix, src/hosts/Windows/apply.ps1, src/platforms/Windows/modules/system/Sync-TerminalActivation.ps1"
---

# Activation scripts and naming

## Naming conventions

All activation entry names — `home.activation.*`, `system.activationScripts.*`, and `nucleus.terminalActivations.*` — use these rules:

- **kebab-case only**: `cloud-drives-setup`, not `cloudDrivesSetup` or `cloud_drives_setup`.
- **verb-first**: `provision-dev-repos`, `install-pwsh-yaml`, `merge-obsidian-json`.
- **Host-prefixed when OS-specific**: `macos-configure-finder-sidebar`, `nixos-launch-nvim`.
- **No prefix when cross-platform**: `cloud-drives-setup`, `provision-dev-repos`, `wait-for-sops-secrets`.
- **No `nucleus-` prefix**: the project name is redundant.
- **`protect`/`unprotect` for symlink hardening** follows the same rules — `home.activation.macos-protect-icloud-downloads-symlink` needs the `macos-` prefix. Only generated `config-utils.nix` names (`unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*`) are exempt.

These rules apply uniformly across `home.activation`, `system.activationScripts`, and `nucleus.terminalActivations`. The cross-boundary mapping table lives in `.agents/instructions/cross-host-feature-parity.instructions.md`.

### Exempt classes

1. **Generated names** from `config-utils.nix`: `unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*`.
2. **Built-in Home Manager phases**: `linkGeneration`, `writeBoundary`, `checkLinkTargets`, `setupLaunchAgents`, `installPackages`.
3. **`sops-nix` entries**: framework-defined.
4. **nix-darwin system activationScripts**: only the hardcoded names (`extraActivation`, `postActivation`, `preActivation`) work; custom names are silently ignored.

### DAG ordering references

Use the exact kebab-case name in `entryAfter [...]` or `entryBefore [...]`. For built-in phases, use the framework-provided name (e.g., `"linkGeneration"`, `"writeBoundary"`). Shared DAG dependency names are in `src/modules/lib/activation-dag.nix`.

### References in documentation and comments

All references to activation entry names in documentation, code comments, echo messages, and script headers use the same kebab-case verb-first convention. Stale camelCase references must be updated alongside the rename.

---

## nix-darwin fragment convention

nix-darwin only honors the hardcoded `preActivation` / `extraActivation` / `postActivation` fragment names — any other `system.activationScripts` name is silently ignored. Never invent custom darwin fragment names.

Every fragment MUST carry a header comment naming its owning module so its origin is traceable, e.g.:

```nix
# Fragment from src/modules/posix-sops.nix
system.activationScripts.postActivation.text = lib.mkAfter ''
  ...fragment body...
'';
```

---

All activation blocks use the **activation bundle subprocess pattern**: scripts live in `src/scripts/`, assembled into a single Nix derivation (`src/modules/lib/script-tree.nix`), and invoked as subprocesses. This eliminates `builtins.readFile` embedding, `__TOKEN__` placeholders, and `+` concatenation.

---

## Activation bundle architecture

`src/modules/lib/script-tree.nix` builds a `nucleus-script-tree` derivation containing all scripts from `src/scripts/` bundled into `$out/src/scripts/` with the same subtree structure, making `$out/` the repo root.

Every bundle script: sets `SCRIPT_DIR` from `$0`, sources libs via `"$SCRIPT_DIR/../lib/<name>.sh"`, accepts per-user values as CLI positional args, executes as a standalone subprocess.

**Adding a new script:** create it in `src/scripts/` (cross-platform), `src/platforms/<Platform>/scripts/` (platform-specific), or `src/hosts/<Host>/scripts/` (host-only). Follow the SCRIPT_DIR + lib sourcing pattern. It is automatically included. Invoke from Nix as `"${activationBundle}/src/scripts/<path>.sh" <pos-arg1> <pos-arg2>`.

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
home.activation.protect-foo = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "moduleName" "$HOME/.config/foo"
'';

# Out-of-store symlinks bulk: manage-out-of-store-symlinks
home.activation.protect-out-of-store-symlinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  "${activationBundle}/src/scripts/configs/manage-out-of-store-symlinks.sh" "protect" "home.nix" '${builtins.toJSON paths}' "${pkgs.jq}/bin/jq"
'';
```

Rules:

- Use `activationBundle` from `pkgs.callPackage ./lib/script-tree.nix { }` — never hardcode a store path.
- Use `"${activationBundle}/src/scripts/<path>.sh"` — the leading `"` makes Nix expand the store path.
- Positional CLI args for all per-user values. No `__TOKEN__` placeholders.
- Use `lib.escapeShellArg` for values going into shell single-quoted context (prevents injection).
- Use `builtins.toJSON` for structured data (lists, attrsets) and pass as a single quoted argument.
- Use double quotes for store paths (`"${pkgs.jq}/bin/jq"`).
- `$HOME` is preserved in Nix `''` strings (`$` passes literally unless followed by `{`).

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

- Start with `set -euo pipefail` (except scripts that intentionally allow failures).
- **Hard-error on required-op failure.** A required convergence or configuration operation that fails must abort the activation (POSIX `die`/`error` + `exit 1`; PowerShell `Write-NucleusError` + `throw`). `warn`/`Write-NucleusWarning` + continue is banned for required operations — see `.agents/instructions/error-handling.instructions.md`.
- Always define `SCRIPT_DIR` — never reference `$REPO_ROOT` at runtime.
- Source libs via SCRIPT_DIR-relative path. Never use `${repoRoot}` or hardcoded paths.
- Use descriptive variable names with a script-specific prefix (e.g., `_mqi_` for merge-qtpass-ini).
- Do not define functions as `main()` — scripts run top-to-bottom.
- No Nix `__TOKEN__` placeholders — all per-user values come as CLI positional args.
- No shebang in activation bundle scripts — the bundle derivation sets bash as the interpreter.

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

Terminal activations (`nucleus.terminalActivations`) are a **last resort**. Never add a new entry unless all three criteria are met:

1. **TCC constraint**: the command MUST run in the user's terminal context (outside sudo/Nix activation) — macOS TCC grants (Full Disk Access, Accessibility) would be lost inside the sudo process tree during `darwin-rebuild switch`.
2. **No alternative**: the command cannot be refactored into a Nix declarative option, Home Manager activation entry, or system activation script.
3. **Documented constraint**: the technical constraint is documented inline with a `# WHY: terminal-activations (last resort):` comment at the call site.

Commands that do not need TCC-sensitive context (FDA, Accessibility, Screen Recording, Automation) should run as a normal Nix/Home Manager activation entry. Terminal activations are inherently imperative (eval'd from a manifest file) and bypass the declarative Nix model.

Every `nucleus.terminalActivations` entry must have a `# WHY: terminal-activations (last resort):` comment explaining why the Nix activation path cannot work.

macOS `darwin-rebuild switch` runs as root (via sudo). Activation scripts inside that process tree lose macOS TCC grants. Terminal activations escape the sudo process tree, so TCC grants are inherited from the user's shell session. On Linux and Windows there is no TCC concept — if a terminal activation is added for a non-mACOS host, it must have an equally compelling documented reason.

See `src/modules/terminal-activations.nix` for the canonical module definition and policy text.
