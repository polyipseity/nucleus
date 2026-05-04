---
description: "Use when adding or changing capabilities that may apply to multiple hosts (macOS, NixOS, Windows). Enforces cross-host parity-first design and explicit rationale for platform-specific exceptions."
name: "Cross-Host Feature Parity"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/windows/**/*.yml, scripts/**, src/scripts/**, AGENTS.md, .agents/instructions/**/*.md"
---

# Cross-Host Feature Parity

## Goal

- Default to **parity-first** changes: apply new capabilities to as many hosts
  as practical in the same change.
- Avoid one-host features unless there is a concrete platform constraint.
- Keep host orchestration thin and push reusable behavior into shared modules
  (`src/modules/*.nix` and `src/modules/windows/*.ps1`) or declarative state
  files (`src/hosts/windows/*.dsc.yml`).

## Feature scope triage (required)

For every new capability, evaluate all three hosts before coding:

1. macOS (`src/hosts/macbook/` + shared modules)
2. NixOS (`src/hosts/nixos/` + shared modules)
3. Windows (`src/hosts/windows/` + `src/modules/windows/`)

If a capability can exist on more than one host, implement those hosts in the
same change whenever feasible.

## Where to implement

- **POSIX shared behavior** (applies to both macOS and NixOS):
  centralize in `src/modules/*.nix`.
- **Windows declarative state**: prefer `src/hosts/windows/system.dsc.yml` or
  `src/hosts/windows/user.dsc.yml` when a WinGet DSC resource can represent it.
- **Windows reusable imperative logic**: keep in
  `src/modules/windows/*.ps1`; keep `src/hosts/windows/apply.ps1`
  orchestration-only.

## Package parity rules

- When adding a cross-host CLI tool to `src/modules/core.nix`, check whether
  a Windows equivalent should be added to `src/hosts/windows/system.dsc.yml`.
- When adding a Windows CLI package to `system.dsc.yml`, check whether POSIX
  hosts should also receive it through `core.nix`.
- If parity is intentionally not applied, document why in code comments and in
  the change summary.

## Secrets and wallpaper parity rules

- Keep secret provisioning behavior symmetrical in intent:
  - POSIX: `src/modules/secrets.nix`
  - Windows: `src/modules/windows/secrets.ps1` wired by `apply.ps1`
- Keep wallpaper provisioning symmetrical in intent:
  - POSIX: `src/modules/wallpapers.nix`
  - Windows: `src/modules/windows/wallpapers.ps1` + `user.dsc.yml`
- Stale cleanup rules must be preserved on every host implementation.

## Allowed platform-specific exceptions

Single-host implementation is allowed only when the feature depends on
platform-specific primitives (for example: macOS defaults domains, NixOS kernel
modules, Windows registry/DSC resources).

When that happens, add a short WHY comment in code explaining why parity is not
possible or not desirable.

## Pre-merge parity checklist

- [ ] Feature scope evaluated for macOS, NixOS, and Windows.
- [ ] Multi-host implementation completed where practical.
- [ ] Shared logic extracted into shared modules where possible.
- [ ] Platform-specific exceptions documented with WHY comments.
- [ ] Related instructions/AGENTS guidance updated when invariants changed.
