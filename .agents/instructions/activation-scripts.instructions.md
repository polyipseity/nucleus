---
description: "Use when adding, renaming, or reviewing activation entries, or adding or editing activation scripts in Nix modules. Covers naming conventions, activation bundle architecture, inline activation rules, standalone script patterns, prohibited patterns, and conventions."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh, src/modules/terminal-activations.nix, src/hosts/Windows/apply.ps1, src/platforms/Windows/modules/system/Sync-TerminalActivation.ps1"
---

# Activation scripts and naming

## Naming conventions

Entry names for `home.activation.*`, `system.activationScripts.*`, and `nucleus.terminalActivations.*` are kebab-case and verb-first: `provision-dev-repos`, `merge-obsidian-json`. Add the host prefix when the entry is OS-specific (`macos-configure-finder-sidebar`, `nixos-launch-nvim`), no prefix when it is cross-platform (`cloud-drives-setup`, `wait-for-sops-secrets`). Never use a `nucleus-` prefix. `protect`/`unprotect` for symlink hardening follows the same rules, so `home.activation.macos-protect-icloud-downloads-symlink` needs the `macos-` prefix.

Exempt names: generated `config-utils.nix` names (`unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*`), built-in Home Manager phases (`linkGeneration`, `writeBoundary`, `checkLinkTargets`, `setupLaunchAgents`, `installPackages`), and `sops-nix` entries.

`entryAfter [...]` and `entryBefore [...]` take the exact kebab-case name, or the framework-provided name for built-in phases. Shared DAG dependency names are in `src/modules/lib/activation-dag.nix`. The cross-boundary mapping to PowerShell names and stage labels is in `cross-host-feature-parity.instructions.md`.

Rename references everywhere: docs, comments, echo messages, script headers.

## nix-darwin fragment convention

nix-darwin only honors the hardcoded names `preActivation`, `extraActivation`, and `postActivation`. Any other `system.activationScripts` name is silently ignored, so never invent one. Every fragment carries a header comment naming its owning module:

```nix
# Fragment from src/modules/posix/gnupg.nix
system.activationScripts.postActivation.text = lib.mkAfter ''
  ...fragment body...
'';
```

## Bundle architecture

`src/modules/lib/script-tree.nix` builds `nucleus-script-tree`, which bundles `src/scripts/` into `$out/src/scripts/` with the same subtree layout, so `$out/` is the repo root. A new script in `src/scripts/` (cross-platform), `src/platforms/<Platform>/scripts/` (platform), or `src/hosts/<Host>/scripts/` (host) is picked up automatically and invoked as `"${activationBundle}/src/scripts/<path>.sh" <pos-arg1> <pos-arg2>`.

Every bundle script sets `SCRIPT_DIR` from `$0`, sources libs via `"$SCRIPT_DIR/../lib/<name>.sh"`, takes per-user values as CLI positional args, and runs as a standalone subprocess. That keeps `builtins.readFile` embedding, `__TOKEN__` placeholders, and `+` concatenation out of activation bodies.

```nix
home.activation.some-step = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  "${activationBundle}/src/scripts/configs/script-name.sh" \
    "${pkgs.tool}/bin/tool" \
    '${builtins.toJSON nixValue}'
'';
```

Rules:

- Bind `activationBundle` via `pkgs.callPackage ./lib/script-tree.nix { }`; never hardcode a store path.
- Write the bundle path as `"${activationBundle}/src/scripts/<path>.sh"`. The leading `"` is what makes Nix expand the store path.
- Pass every per-user value as a positional CLI arg, never `__TOKEN__` placeholders and never env vars.
- `lib.escapeShellArg` for values going into a shell single-quoted context; `builtins.toJSON` for structured data (lists, attrsets), passed as one quoted argument.
- Double quotes around store paths (`"${pkgs.jq}/bin/jq"`). `$HOME` survives Nix `''` strings: `$` is literal unless followed by `{`.
- Use `${...}` interpolation, never `+` concatenation, in any expression that produces a script body (activation blocks, `pkgs.writeShellScript`, `pkgs.writeTextFile.text`).

Pure inline is the one exception: at most 3 lines, no conditionals, no loops, no external tool, written straight into the block. Anything larger needs a bundle script.

## Standalone scripts for launchd/systemd

A consumer that needs an executable store path (launchd agent, systemd service, cron job) gets `pkgs.writeShellScript`, or `writeTextFile` when a specific shebang is required. These are not activation blocks: they may use `builtins.readFile` plus `builtins.replaceStrings` for token substitution, while still using interpolation rather than concatenation.

```nix
someScript = pkgs.writeShellScript "script-name" ''
  #!${pkgs.bash}/bin/bash
  set -eu
  ${builtins.readFile ../scripts/lib/some-lib.sh}
  some_function "${arg}"
'';
```

## Script conventions

```bash
# shellcheck shell=sh
# <description of what this script does>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening.sh"

_arg1="$1"
```

- Start with `set -euo pipefail`, except where failure is the point.
- Hard-error on a required-op failure: POSIX `die`/`error` then `exit 1`, PowerShell `Write-NucleusError` then `throw`. `warn`/`Write-NucleusWarning` and continue is banned for a required operation (`output-handling.instructions.md`).
- Always define `SCRIPT_DIR`. Never reference `$REPO_ROOT`, `${repoRoot}`, or a hardcoded path at runtime.
- Prefix script variables per script (`_mqi_` for merge-qtpass-ini).
- No `main()` function. Scripts run top to bottom.
- No shebang in a bundle script; the bundle derivation supplies the interpreter.

## Prohibited patterns

- `builtins.readFile` inside an activation block body, and `builtins.replaceStrings` inside an activation block. The pure inline pattern is the only exception, and it contains no readFile.
- String concatenation (`+ ''...''`, `) + builtins.readFile ...`) in a script-producing expression.
- `__TOKEN__` placeholders in bundle scripts, or env vars as a data-passing shim.
- `$REPO_ROOT` at runtime in a bundle script.
- A wrapper script that only sources a lib and calls functions. Use `managed-symlink` or `manage-out-of-store-symlinks`.
- An outer string wrapping a script invocation. The invocation string is the activation body directly.
- Inline Python in an activation block. Wrap it in a bundle script.

Every exception needs an inline `# WHY:` comment in the Nix expression stating the technical constraint that blocks the standard pattern.

## Terminal activations

`nucleus.terminalActivations` is a last resort. An entry needs all three: the command must run in the user's terminal context because it needs macOS TCC grants that the sudo process tree of `darwin-rebuild switch` would lose, no declarative or activation-entry alternative exists, and the call site carries a `# WHY: terminal-activations (last resort):` comment. Anything not TCC-sensitive runs as a normal Nix or Home Manager activation entry. A non-macOS host needs an equally compelling documented reason.
