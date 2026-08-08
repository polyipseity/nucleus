---
description: "Use when adding, renaming, or reviewing activation entries in Nix modules. Covers naming conventions, host prefix rules, and exempt classes for Home Manager and system activations."
name: "Activation Naming"
applyTo: "src/**/*.nix"
---

# Activation naming

## Conventions

All activation entry names — `home.activation.*`, `system.activationScripts.*`, and `nucleus.terminalActivations.*` — follow these rules:

- **kebab-case only.** Use hyphens to separate words: `cloud-drives-setup`, not `cloudDrivesSetup` or `cloud_drives_setup`.
- **verb-first.** Start every name with a verb or action word: `provision-dev-repos`, `install-pwsh-yaml`, `merge-obsidian-json`.
- **Host-prefixed when OS-specific.** If the activation only applies to one OS, prefix with `macos-` or `nixos-`:
  - `macos-configure-finder-sidebar`, `nixos-launch-nvim`
- **No prefix when cross-platform.** If the activation applies to multiple operating systems, no host prefix:
  - `cloud-drives-setup`, `provision-dev-repos`, `wait-for-sops-secrets`
- **No `nucleus-` prefix.** The project name is redundant — all activations in this repo are nucleus-specific.
- **Keep `protect`/`unprotect` for symlink hardening.** The shared protect/unprotect pattern in `home.nix` uses `protect-out-of-store-symlinks` / `unprotect-out-of-store-symlinks`. Generated entries from `config-utils.nix` use the underscored `unprotectSymlink_${name}` / `protectSymlink_${name}` / `mergeConfig_${name}` pattern — these are exempt.

## Exempt classes

The following activation entry types are **not** subject to the naming policy:

1. **Generated names** from `config-utils.nix`: `unprotectSymlink_*`, `protectSymlink_*`, `mergeConfig_*` — these are dynamically generated from data, not manually authored.
2. **Built-in Home Manager phases**: `linkGeneration`, `writeBoundary`, `checkLinkTargets`, `setupLaunchAgents`, `installPackages` — these are framework-defined.
3. **`sops-nix` entries**: framework-defined names.
4. **nix-darwin system activationScripts**: only the hardcoded names (`extraActivation`, `postActivation`, `preActivation`) work; custom names are silently ignored.

## DAG ordering references

When referencing another activation in `entryAfter [...]` or `entryBefore [...]`, use the exact kebab-case name of the target entry. For built-in phases, use the framework-provided name (e.g., `"linkGeneration"`, `"writeBoundary"`).

Shared DAG dependency names are defined in `src/modules/lib/activation-dag.nix`.

## References in documentation and comments

All references to activation entry names in documentation, code comments, echo
messages, script header comments, and any other human-readable text must use the
same kebab-case verb-first naming convention. Stale camelCase references to
renamed activations must be updated alongside the rename.
