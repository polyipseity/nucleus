---
description: "Use when adding, renaming, or reviewing activation entries or scripts."
name: "Activation Script Conventions"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/services/*.nix, src/scripts/**/*.sh, src/modules/terminal-activations.nix, src/hosts/Windows/apply.ps1, src/platforms/Windows/modules/system/Sync-TerminalActivation.ps1"
---

# Activation scripts and naming

## Naming

`home.activation.*`, `system.activationScripts.*`, and `nucleus.terminalActivations.*` entries are lowerCamelCase and verb-first (`provisionDevRepos`, `mergeObsidianJson`). Add the host prefix for OS-specific entries (`macosConfigureFinderSidebar`, `nixosLaunchNvim`), none for cross-platform ones (`cloudDrivesSetup`, `waitForSopsSecrets`). No `nucleus-` prefix. Symlink `protect`/`unprotect` follows the same rule (`home.activation.macosProtectIcloudDownloadsSymlink`).

Exempt names only: generated `config-utils.nix` names (`unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*`), Home Manager built-ins (`linkGeneration`, `writeBoundary`, `checkLinkTargets`, `setupLaunchAgents`, `installPackages`, `preActivation`, `extraActivation`, `postActivation`, `checkFilesChanged`, `onFilesChange`), upstream `hermesAgentSetup`, and sops-nix `sops-nix`. Do not exempt a nucleus-owned key.

`entryAfter [...]` and `entryBefore [...]` take exact keys or framework-provided names; shared dependency names live in `src/modules/lib/activation-dag.nix`. The PowerShell/stage mapping is in `cross-host-feature-parity.instructions.md`. Rename references everywhere: docs, comments, echo messages, script headers.

nix-darwin honors only `preActivation`, `extraActivation`, and `postActivation`; custom `system.activationScripts` names are evaluated but never called. Each fragment carries a header naming its owning module:

```nix
# Fragment from src/modules/posix/gnupg.nix
system.activationScripts.postActivation.text = lib.mkAfter ''
  ...fragment body...
'';
```

## Bundle architecture

`src/modules/lib/script-tree.nix` builds `nucleus-script-tree`, bundling `src/scripts/` into `$out/src/scripts/` with the same layout, so `$out/` is the repo root. New scripts under `src/scripts/`, `src/platforms/<Platform>/scripts/`, or `src/hosts/<Host>/scripts/` are picked up automatically and invoked as `"${activationBundle}/src/scripts/<path>.sh" <pos-arg1> <pos-arg2>`.

Each bundle script sets `SCRIPT_DIR` from `$0`, sources libs via `"$SCRIPT_DIR/../lib/<name>.sh"`, takes per-user values as positional args, and runs standalone. That keeps `builtins.readFile`, `__TOKEN__`, and `+` out of activation bodies.

```nix
home.activation.someStep = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  "${activationBundle}/src/scripts/configs/script-name.sh" \
    "${pkgs.tool}/bin/tool" \
    '${builtins.toJSON nixValue}'
'';
```

Bind `activationBundle` with `pkgs.callPackage ./lib/script-tree.nix { }`, never a hardcoded store path. Write the bundle path with the leading quote so Nix expands it. Use `lib.escapeShellArg` for shell single-quoted values and `builtins.toJSON` for structured data as one quoted argument. Double-quote store paths; `$HOME` survives Nix `''` strings. Use `${...}` interpolation, never `+`, in any script-producing expression. Pure inline is the sole exception: at most 3 lines, no conditionals, loops, or external tools.

Standalone store executables (launchd, systemd, cron) use `pkgs.writeShellScript`, or `writeTextFile` for a specific shebang. They may use `readFile` plus `replaceStrings`, still with interpolation rather than concatenation.

## Script conventions

Start with `set -euo pipefail` except where failure is the point. Hard-error on required-op failure (`die`/`error` then `exit 1`, PowerShell `Write-NucleusError` then `throw`); `warn` and continue is banned for required work (`output-handling.instructions.md`). Always define `SCRIPT_DIR`; never reference `$REPO_ROOT`, `${repoRoot}`, or a hardcoded path at runtime. Prefix variables per script (`_mqi_` for merge-qtpass-ini). No `main()`; scripts run top to bottom. The bundle rewrites `#!/usr/bin/env bash` to pinned bash; repo copies keep the env shebang for direct invocation.

## Prohibited patterns

`builtins.readFile` and `builtins.replaceStrings` inside activation bodies (pure inline contains neither); string concatenation in script-producing expressions; `__TOKEN__` in bundle scripts or env vars as a data shim; `$REPO_ROOT` at runtime in a bundle; a wrapper that only sources a lib and calls functions (use `managed-symlink` or `manage-out-of-store-symlinks`); an outer string wrapping an invocation; inline Python in an activation block. Every exception needs an inline `# WHY:` stating the technical constraint.

## Terminal activations

`nucleus.terminalActivations` is a last resort. All three must hold: the command needs the user's terminal context for macOS TCC grants that the `darwin-rebuild switch` sudo tree loses, no declarative or activation alternative exists, and the call site carries `# WHY: terminal-activations (last resort):`. Non-TCC work runs as a regular Nix or Home Manager activation entry. A non-macOS host needs an equally compelling documented reason.
