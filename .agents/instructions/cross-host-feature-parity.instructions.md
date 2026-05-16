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
  (`src/modules/*.nix` and `src/hosts/windows/modules/*.ps1`) or declarative state
  files (`src/hosts/windows/*.dsc.yml`).

## Feature scope triage (required)

For every new capability, evaluate all three hosts before coding:

1. macOS (`src/hosts/macbook/` + shared modules)
2. NixOS (`src/hosts/nixos/` + shared modules)
3. Windows (`src/hosts/windows/` + `src/hosts/windows/modules/`)

If a capability can exist on more than one host, implement those hosts in the
same change whenever feasible.

## Feature-by-feature parity review (required)

When parity debt is being reduced (especially Windows vs macOS/NixOS), evaluate
existing capabilities **one-by-one** instead of batching assumptions.

For each feature discovered on any host, record one explicit decision:

1. **Implement parity now** (preferred)
2. **Already in parity**
3. **Not practical yet** (must include a short WHY in code and change summary)

Do not skip categories. At minimum review: packages/tools, shell/dev workflow,
security posture, desktop/UI behavior, remote-access behavior, secrets, editor
experience, git/signing behavior, power/network posture, and automation hooks.

When reviewing desktop/UI behavior, apply a minimal-chrome parity lens:
prefer reducing persistent chrome (menu extras, taskbar buttons, recents,
always-visible docks/panels) when equivalent keyboard/command workflows remain
available. At the same time, preserve high-signal visibility defaults (for
example hidden files, file extensions, status/path bars, and explicit metadata)
unless there is a concrete host constraint.

Typography is also a parity category: prefer a shared open-source font baseline
(Latin sans/serif/monospace + Nerd Font + CJK) across macOS, NixOS, and
Windows when practical.

## Where to implement

- **POSIX shared behavior** (applies to both macOS and NixOS):
  centralize in `src/modules/*.nix`.
- **Windows declarative state**: prefer `src/hosts/windows/system.dsc.yml` or
  `src/hosts/windows/user.dsc.yml` when a WinGet DSC resource can represent it.
- **Windows reusable imperative logic**: keep in
  `src/hosts/windows/modules/*.ps1`; keep `src/hosts/windows/apply.ps1`
  orchestration-only.
- If a Windows parity feature cannot be represented declaratively, implement it
  in a reusable module with an explicit **cleanup/deconfiguration path** so the
  feature can be safely disabled later.

## Imperative fallback safety (Windows)

If a parity feature requires imperative Windows code, enforce all of the
following in both configuration and deconfiguration paths:

- **Managed-scope only**: change only declaratively managed blocks/keys/files;
  never overwrite, delete, or mutate unrelated user-managed content.
- **Fail-fast on unsafe state**: stop with a clear error when ownership,
  preconditions, or target state are ambiguous.
- **Idempotent convergence**: repeated applies must not duplicate managed
  content or repeatedly mutate equivalent values.
- **Idempotent cleanup**: disabling a feature must remove only managed state
  and be a no-op when that managed state is already absent.
- **Explicit toggle wiring**: expose enable/disable in
  `src/hosts/windows/apply.ps1` and wire cleanup when disabled.

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
  - Windows: `src/hosts/windows/modules/sync-secret.ps1` wired by `apply.ps1`
- Keep wallpaper provisioning symmetrical in intent:
  - POSIX: `src/modules/wallpapers.nix`
  - Windows: `src/hosts/windows/modules/sync-wallpaper.ps1` + `user.dsc.yml`
- Stale cleanup rules must be preserved on every host implementation.

## Cloud-drive parity rules

- Treat cloud-drive capabilities as parity-first across macOS, NixOS, and
  Windows for both mounts and replicas.
- Directionality invariant: mounts are live/bidirectional access surfaces;
  replicas are pull-only read-only mirrors (remote -> local) for automation.
- Do not add push/bisync execution paths for replicas in any host unless a
  new repository policy explicitly changes this invariant.
- Preserve stable provider identity keys (`id`, `remoteName`) while allowing
  host-appropriate presentation labels.
- Keep managed mount/replica local paths as real directories on every host
  unless a documented platform exception applies.
- The current documented exception is macOS-only: `~/clouds/iCloudReplica`
  may be a symlink to `~/Library/Mobile Documents` to avoid duplicating native
  iCloud storage.
- When implementing or changing a cloud-drive exception, document WHY in code
  and add/update tests proving the exception is scoped to the intended host.

## Allowed platform-specific exceptions

Single-host implementation is allowed only when the feature depends on
platform-specific primitives (for example: macOS defaults domains, NixOS kernel
modules, Windows registry/DSC resources).

When that happens, add a short WHY comment in code explaining why parity is not
possible or not desirable.

If an exception hides information or controls (for example auto-hide,
taskbar/menu toggles, or hidden-file toggles), the WHY comment must explain the
tradeoff and name the alternate access path (shortcut, command, or menu route).

## Pre-merge parity checklist

- [ ] Feature scope evaluated for macOS, NixOS, and Windows.
- [ ] Existing feature inventory reviewed one-by-one with explicit decisions.
- [ ] Multi-host implementation completed where practical.
- [ ] Shared logic extracted into shared modules where possible.
- [ ] Platform-specific exceptions documented with WHY comments.
- [ ] Related instructions/AGENTS guidance updated when invariants changed.
