---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/**/*.nix, src/**/*.ps1, scripts/gc.*, src/hosts/Windows/**/*.yml"
---

# Cross-Host Feature Parity

## Goal

- Default to **parity-first** changes: apply new capabilities to as many hosts as practical in the same change.
- Avoid one-host features unless there is a concrete platform constraint.
- Keep host orchestration thin and push reusable behavior into shared modules (`src/modules/*.nix` and `src/hosts/Windows/modules/*.ps1`) or declarative state files (`src/hosts/Windows/*.dsc.yml`).
- **Avoid special-casing in module logic.** When a feature requires per-host differences, refactor shared behavior into parameterized abstractions rather than adding `if-else` branches or duplicating files. Special cases in activation scripts and Nix conditionals should be the exception, not the default.

## Feature scope triage (required)

For every new capability, evaluate all three hosts before coding:

1. macOS (`src/hosts/MacBook/` + shared modules)
2. NixOS (`src/hosts/NixOS/` + shared modules)
3. Windows (`src/hosts/Windows/` + `src/hosts/Windows/modules/`)

If a capability can exist on more than one host, implement those hosts in the same change whenever feasible.

## Feature-by-feature parity review (required)

When parity debt is being reduced (especially Windows vs macOS/NixOS), evaluate existing capabilities **one-by-one** instead of batching assumptions.

For each feature discovered on any host, record one explicit decision:

1. **Implement parity now** (preferred)
2. **Already in parity**
3. **Not practical yet** (must include a short WHY in code and change summary)

Do not skip categories. At minimum review: packages/tools, shell/dev workflow, security posture, desktop/UI behavior, remote-access behavior, secrets, editor experience, git/signing behavior, power/network posture, and automation hooks.

When reviewing desktop/UI behavior, apply a minimal-chrome parity lens: prefer reducing persistent chrome (menu extras, taskbar buttons, recents, always-visible docks/panels) when equivalent keyboard/command workflows remain available. At the same time, preserve high-signal visibility defaults (for example hidden files, file extensions, status/path bars, and explicit metadata) unless there is a concrete host constraint.


## Where to implement

- **POSIX shared behavior** (applies to both macOS and NixOS): centralize in `src/modules/*.nix`.
- **Windows declarative state**: prefer `src/hosts/Windows/system.dsc.yml`, `src/hosts/Windows/system-packages.dsc.yml`, `src/hosts/Windows/user.dsc.yml`, `src/hosts/Windows/user-env.dsc.yml`, or `src/hosts/Windows/user-context.dsc.yml` when a WinGet DSC resource can represent it.
- **Windows reusable imperative logic**: keep in `src/hosts/Windows/modules/*.ps1`; keep `src/hosts/Windows/apply.ps1` orchestration-only.
- If a Windows parity feature cannot be represented declaratively, implement it in a reusable module with an explicit **cleanup/deconfiguration path** so the feature can be safely disabled later.

## Imperative fallback safety (Windows)

If a parity feature requires imperative Windows code, enforce all of the following in both configuration and deconfiguration paths:

- **Managed-scope only**: change only declaratively managed blocks/keys/files; never overwrite, delete, or mutate unrelated user-managed content.
- **Fail-fast on unsafe state**: stop with a clear error when ownership, preconditions, or target state are ambiguous.
- **Idempotent convergence**: repeated applies must not duplicate managed content or repeatedly mutate equivalent values.
- **Idempotent cleanup**: disabling a feature must remove only managed state and be a no-op when that managed state is already absent.
- **Explicit toggle wiring**: expose enable/disable in `src/hosts/Windows/apply.ps1` and wire cleanup when disabled.

## Service lifecycle cleanup

When a service declaration is removed or disabled, each platform handles cleanup differently. Documented here so maintainers know what to expect.

- **macOS (launchd) / NixOS (systemd)** — Automatic. Nix removes the unit file and stops the service on re-apply.
- **Windows native SCM services** (Caddy, LiteLLM) — Explicit. Each `Sync-*Service.ps1` module implements its own cleanup when `-Enabled:$false`: `Stop-Service` + `sc.exe delete`. The cleanup is manual imperative code.
- **Windows scheduled tasks** (cloud-drive, CamillaDSP, Discord Music RPC, etc.) — Same explicit pattern. Each `Sync-*` module calls `Unregister-ScheduledTask` when disabled.

When adding a new Windows service module, always implement both the enable and disable paths. Verify disable removes the managed service/task state completely by testing with the toggle off.

### Service startup failure policy

Services that fail to start during activation emit a warning but do not abort the activation. This applies to all hosts. Watchdog retries are handled separately per service.

## Package parity rules

- When adding a cross-host CLI tool to `src/modules/core.nix`, check whether a Windows equivalent should be added to `src/hosts/Windows/system-packages.dsc.yml`.
- When adding a Windows CLI package to `system-packages.dsc.yml`, check whether POSIX hosts should also receive it through `core.nix`.
- **When adding a package that exists in both nixpkgs and Homebrew**, add it to `overlappingPackages` in `src/modules/core.nix` (not spread across host files). Use `platforms` to restrict darwin-only packages and `category` to set the install backend policy.
- Remove duplicate declarations from `src/hosts/NixOS/desktop.nix` when a package is already delivered via `core.nix`'s `sharedPackages`.
- **Windows source builds use git hash pinning.** When a tool must be compiled from source on Windows (not available via WinGet/Scoop), pin by git commit hash, not a tag or branch. Document the build steps in a reusable `Build-<Tool>.ps1` module under `src/hosts/Windows/modules/` and wire it into the activation DAG in `apply.ps1`.

## Secrets and wallpaper parity rules

- Keep secret provisioning behavior symmetrical in intent:
  - POSIX: `src/modules/secrets.nix`
  - Windows: `src/hosts/Windows/modules/sync-secret.ps1` wired by `apply.ps1`
- Keep wallpaper provisioning symmetrical in intent:
  - POSIX: `src/modules/wallpapers.nix`
  - Windows: `src/hosts/Windows/modules/sync-wallpaper.ps1` + `user.dsc.yml`
- Stale cleanup rules must be preserved on every host implementation.

## Cloud-drive parity rules

- Treat cloud-drive capabilities as parity-first across macOS, NixOS, and Windows for both mounts and replicas.
- Directionality invariant: mounts are live/bidirectional access surfaces; replicas are pull-only read-only mirrors (remote -> local) for automation. Do not add push/bisync execution paths for replicas unless a new repository policy explicitly changes this invariant.
- Preserve stable provider identity keys (`id`, `remoteName`) while allowing host-appropriate presentation labels.
- Keep managed mount/replica local paths as real directories on every host unless a documented platform exception applies.
- The current documented exception is macOS-only: `~/clouds/iCloudReplica` may be a symlink to `~/Library/Mobile Documents` to avoid duplicating native iCloud storage.
- When implementing or changing a cloud-drive exception, document WHY in code and add/update tests proving the exception is scoped to the intended host.

## Allowed platform-specific exceptions

Single-host implementation is allowed only when the feature depends on platform-specific primitives (for example: macOS defaults domains, NixOS kernel modules, Windows registry/DSC resources).

When that happens, add a short WHY comment in code explaining why parity is not possible or not desirable.

If an exception hides information or controls (for example auto-hide, taskbar/menu toggles, or hidden-file toggles), the WHY comment must explain the tradeoff and name the alternate access path (shortcut, command, or menu route).

## Pre-merge parity checklist

- [ ] Feature scope evaluated for all three hosts (macOS, NixOS, Windows).
- [ ] Multi-host implementation done where practical; exceptions have WHY comments.
- [ ] Shared logic extracted into shared modules where possible.
- [ ] Related instructions/AGENTS guidance updated when invariants changed.

## GC and Retention Policy

Timing values are specified directly at their point of use. Find or change a retention interval in the relevant source file:

| Category                     | Source files                                                                                                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix store GC, HM expiry      | `src/modules/posix-base.nix`, `scripts/gc.sh`                                                                                                                                                                                               |
| macOS timers & defaults      | `src/modules/macos.nix`, `src/hosts/MacBook/defaults.nix`                                                                                                                                                                                   |
| Linux timers & timeouts      | `src/modules/linux.nix`, `src/modules/posix-security.nix`                                                                                                                                                                                   |
| Windows schedules & timeouts | `src/hosts/Windows/system.dsc.yml`, `src/hosts/Windows/system-packages.dsc.yml`, `src/hosts/Windows/user.dsc.yml`, `src/hosts/Windows/user-env.dsc.yml`, `src/hosts/Windows/user-context.dsc.yml`, `src/hosts/Windows/modules/system/*.ps1` |
| Cloud drive caches           | `src/modules/cloud-drives.nix`                                                                                                                                                                                                              |
| AI/LLM timeouts              | `scripts/ai-sync.sh`, `scripts/gc.sh`                                                                                                                                                                                                       |
| Declarative-diff GC items    | `scripts/gc.sh`, `scripts/gc.ps1`                                                                                                                                                                                                           |
| App-level timeouts           | `src/modules/editors.nix`, `src/modules/configs/picard/Picard.ini`                                                                                                                                                                          |

Runtime overrides via `--expiry`/`NUCLEUS_GC_EXPIRY` etc. have precedence: CLI flag > per-tool env var > master flag/env > Nix config default > `7d`. See each source file for available flags.

### Authoring rule

- When changing a timing value, update the actual configuration in the source file listed above. No separate timing manifest needs updating.

## Provisioned Symlink Policy

### Default Rule

Every provisioned symlink must be **writable** AND **delete-protected**.

- **Delete-protection mechanism**: `chflags uchg` (macOS), `chattr +i` (Linux), `icacls /deny` (Windows). Best-effort with warning on failure.

### Read-Only Exception

A symlink MUST be read-only when its target is in the Nix store (or on Windows, when the corresponding POSIX symlink uses a Nix store target). The Nix store target is immutable, making the content effectively read-only.

### Deviation Rule

Any deviation from the default or read-only exception must be documented with:

1. A `# WHY` comment at the creation site.
2. An entry in the exceptions list below with full rationale.

### Cross-Platform Parity

When a symlink exists on both POSIX and Windows, writability semantics MUST match. A read-only symlink on POSIX (Nix store target) must be made read-only on Windows (read-only attribute or restrictive ACL).

### Known Exceptions

| Symlink                                   | Reason                                                                                                         | Platform        |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------- | --------------- |
| `~/.config/discord-music-rpc/config.yaml` | discord-music-rpc overwrites config on startup; read-only target prevents app from discarding managed settings | POSIX + Windows |
