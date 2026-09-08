---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

## Goal

Default to parity-first: same capability on every host where possible. Push reusable behavior into shared modules; avoid special-casing. POSIX uses bash, Windows uses PowerShell — never mix. Differences require WHY comments.

## Implementation pattern

- POSIX (macOS + NixOS): `scripts/*.sh` or `src/scripts/**/*.sh`
- Windows: `scripts/*.ps1` or `src/platforms/Windows/modules/**/*.ps1`
- Shared content: single file in `src/scripts/` per `embedded-content.instructions.md`
- Windows prohibition: no `.sh` paths from Windows runtime code

## Feature scope triage

For every new capability, evaluate all three hosts before writing code:

1. macOS (`src/hosts/MacBook/` + shared modules)
2. NixOS (`src/hosts/NixOS/` + shared modules)
3. Windows (`src/hosts/Windows/` + `src/platforms/Windows/modules/`)

If a capability can exist on more than one host, implement those hosts in the same change.

When reducing parity debt (especially Windows vs macOS/NixOS), evaluate existing capabilities one-by-one. For each feature on any host, record one decision: implement parity now, already in parity, or not practical yet (with a short WHY in code and change summary). At minimum review: packages/tools, shell/dev workflow, security posture, desktop/UI behavior, remote-access behavior, secrets, editor experience, git/signing behavior, power/network posture, and automation hooks.

When reviewing desktop/UI behavior, apply a minimal-chrome parity lens: prefer reducing persistent chrome (menu extras, taskbar buttons, recents, always-visible docks/panels) when equivalent keyboard/command workflows remain available. At the same time, preserve high-signal visibility defaults (hidden files, file extensions, status/path bars, and explicit metadata) unless a host constraint prevents it.

### Host-specific lib/ pattern for per-host config differences

When a config file's application has a native extension-point mechanism that auto-loads override scripts (e.g., direnv's `~/.config/direnv/lib/*.sh`), use the Host-specific lib/ subdirectory convention documented in `app-config-policy.instructions.md`. This prevents `if-else` branches in module logic and prevents deploying dead platform-specific code.

## Where to implement

- **POSIX shared behavior** (macOS and NixOS): centralize in `src/modules/*.nix`.
- **Windows declarative state**: prefer DSC YAML files (`system.dsc.yml`, `system-packages.dsc.yml`, `user.dsc.yml`, `user-env.dsc.yml`, `user-context.dsc.yml`) when a WinGet DSC resource can represent it.
- **Windows reusable imperative logic**: keep in `src/platforms/Windows/modules/*.ps1`; keep `src/hosts/Windows/apply.ps1` orchestration-only.
- If a Windows parity feature cannot be represented declaratively, implement it in a reusable module with an explicit cleanup/deconfiguration path so the feature can be safely disabled later.

## Imperative recovery safety (Windows)

If a parity feature requires imperative Windows code, enforce all of the following in both configuration and deconfiguration paths:

- **Managed-scope only**: change only declaratively managed blocks/keys/files; never overwrite, delete, or mutate unrelated user-managed content.
- **Fail-fast on unsafe state**: stop with a clear error when ownership, preconditions, or target state are ambiguous.
- **Idempotent convergence**: repeated applies must not duplicate managed content or repeatedly mutate equivalent values.
- **Idempotent cleanup**: disabling a feature must remove only managed state and be a no-op when that managed state is already absent.
- **Explicit toggle wiring**: expose enable/disable in `src/hosts/Windows/apply.ps1` and wire cleanup when disabled.

## Service lifecycle cleanup

When a service declaration is removed or disabled:

- **macOS (launchd) / NixOS (systemd)** — Automatic. Nix removes the unit file and stops the service on re-apply.
- **Windows native SCM services** (Caddy, LiteLLM) — Explicit. Each `Sync-*Service.ps1` module implements its own cleanup when `-Enabled:$false`: `Stop-Service` + `sc.exe delete`.
- **Windows scheduled tasks** (cloud-drive, CamillaDSP, Discord Music RPC, etc.) — Same explicit pattern. Each `Sync-*` module calls `Unregister-ScheduledTask` when disabled.

When adding a new Windows service module, always implement both the enable and disable paths. Verify disable removes the managed service/task state completely.

Services that fail to start during activation emit a warning but do not abort the activation. This applies to all hosts. Watchdog retries are handled separately per service.

## Service firing policy

All nucleus-managed services use persistent-daemon semantics by default (auto-start + auto-restart on crash). Services that need periodic work use an internal sleep loop rather than platform timers. The full service classification table, platform templates, persistent daemon registry, periodic oneshot list, and internal loop pattern details are in `service-firing-policy.reference.md`.

Key rules:
- Default is persistent daemon; periodic oneshots are explicit exceptions.
- No explicit rate-limiting or restart-interval settings — platform defaults suffice.
- Services that fail to start emit a warning but do not abort activation.
- macOS-only and POSIX-only services have no cross-host equivalent by design.

## Package parity rules

- When adding a cross-host CLI tool to `src/modules/core.nix`, check whether a Windows equivalent should be added to `src/hosts/Windows/system-packages.dsc.yml`. Vice versa for Windows packages going to POSIX.
- When adding a package in both nixpkgs and Homebrew, add it to `managedPackages` in `src/modules/core.nix` (not spread across host files). See `package-installation-scope.instructions.md` (Managed package classification) for category, platform, and add-workflow rules.
- Remove duplicate declarations from `src/hosts/NixOS/desktop.nix` when a package is already delivered via `core.nix`'s `sharedPackages`.
- Windows source builds use git hash pinning. Pin by commit hash, not tag or branch. Document build steps in `Build-<Tool>.ps1` under `src/platforms/Windows/modules/` and wire into the activation DAG in `apply.ps1`.

## Secrets and wallpaper parity

- POSIX secrets: `src/modules/secrets.nix` + `materialize-user-secrets.sh`; Windows: `Sync-UserSecret.ps1` / `Sync-SecretFile.ps1` wired by `apply.ps1`.
- POSIX wallpapers: `src/modules/wallpapers.nix`; Windows: `Sync-WallpaperInventory.ps1` + `user.dsc.yml`.
- Preserve stale cleanup rules on every host.

## Cloud-drive parity

See `cloud-drives-and-finder.instructions.md` for the full cloud-drive policy. Key parity requirements: treat mounts/replicas parity-first across all hosts, keep managed paths as real directories on all hosts (see cloud-drives-and-finder for the macOS-only iCloud exception), and do not add push/bisync execution paths for replicas.

## Cross-platform script deduplication

Scripts under `src/hosts/<Host>/scripts/` or `src/platforms/<Platform>/scripts/` must implement a feature that is semantically host- or platform-specific. If the feature could apply to any POSIX host, the script belongs in a non-host subdirectory (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, or root of `src/scripts/`).

If the same feature exists on both macOS and NixOS with host-specific implementations, merge into a single POSIX-compatible script using `builtins.replaceStrings` token substitution (preferred) or `case "$(uname)"` dispatch. Merged scripts MUST NOT use the `macos-` or `nixos-` prefix; use natural names per the naming rule. After merging, delete the originals — no backwards-compatibility shims.

## Allowed platform-specific exceptions

Single-host implementation is allowed only when the feature depends on platform-specific primitives (macOS defaults domains, NixOS kernel modules, Windows registry/DSC resources). Add a short WHY comment in code explaining why parity is not possible or not desirable. If an exception masks information or controls (auto-hide, taskbar/menu toggles, hidden-file toggles), the WHY comment must explain the tradeoff and name the alternate access path (shortcut, command, or menu route).

## Pre-merge parity checklist

- Feature scope evaluated for all three hosts (macOS, NixOS, Windows).
- Multi-host implementation done where practical; exceptions have WHY comments.
- Shared logic extracted into shared modules where possible.
- Related instructions/AGENTS guidance updated when invariants changed.

## GC and retention policy

Timing values are specified directly at their point of use. Find or change a retention interval in the relevant source file:

| Category | Source files |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix store GC, HM expiry | `src/modules/posix-base.nix`, `src/scripts/services/nix-store-gc.sh`, `scripts/gc.sh`, `src/modules/lib/gc-options.nix` |
| macOS timers & defaults | `src/platforms/macOS/modules/default.nix`, `src/hosts/MacBook/defaults.nix` |
| Linux timers & timeouts | `src/platforms/NixOS/modules/default.nix`, `src/modules/posix-security.nix` |
| Windows schedules & timeouts | `src/hosts/Windows/system.dsc.yml`, `src/hosts/Windows/system-packages.dsc.yml`, `src/hosts/Windows/user.dsc.yml`, `src/hosts/Windows/user-env.dsc.yml`, `src/hosts/Windows/user-context.dsc.yml`, `src/platforms/Windows/modules/system/*.ps1` |
| Cloud drive caches | `src/modules/cloud-drives.nix` |
| AI/LLM timeouts | `scripts/ai-sync.sh`, `scripts/gc.sh` |
| Declarative-diff GC items | `scripts/gc.sh`, `scripts/gc.ps1` |
| App-level timeouts | `src/modules/editors.nix`, `src/users/default/picard/Picard.ini` |

Runtime overrides via `--expiry`/`NUCLEUS_GC_EXPIRY` and `--generations-keep`/`NUCLEUS_GC_GENERATIONS_KEEP` etc. have precedence: CLI flag > per-tool env var > master flag/env > Nix config default > `7d` / `7`. When changing a timing value, update the actual configuration in the source file listed above. No separate timing manifest needs updating.

## Provisioned symlink policy

Every provisioned symlink must be writable AND delete-protected.

- **Delete-protection mechanism**: `chflags uchg` (macOS), `chattr +i` (Linux), `icacls /deny` (Windows). Best-effort with warning on failure.
- **Read-only exception**: A symlink MUST be read-only when its target is in the Nix store (or on Windows, when the corresponding POSIX symlink uses a Nix store target). The Nix store target is immutable, making the content effectively read-only.
- **Deviation rule**: Any deviation from the default or read-only exception must be documented with a `# WHY:` comment at the creation site and an entry in the exceptions list below.

When a symlink exists on both POSIX and Windows, writability semantics MUST match. A read-only symlink on POSIX (Nix store target) must be made read-only on Windows (read-only attribute or restrictive ACL).

### macOS /usr/local/bin symlink farm

`src/hosts/MacBook/scripts/macos-symlink-farm.sh` manages `/usr/local/bin` symlinks for Nix store entries. It reads `__nucleus_symlink_farm` (space-separated `target->name` pairs), creates/updates symlinks, and GCs stale Nix store entries. Safety: only removes symlinks (`-L`), never regular files, never non-Nix symlinks.

The `__nucleus_symlink_farm` env var is generated in `src/hosts/MacBook/activation.nix` from `appleSdkTools.symlinkFarmTools` plus any extra entries.

## By-design imperative patterns

The following patterns are intentionally imperative and must not be converted to declarative state. Each has a documented technical constraint.

| Pattern | Constraint |
|---------|------------|
| Bootstrap curl (`bootstrap.sh`) | Must work before Nix is installed |
| macOS `defaults write` | No declarative API for macOS preferences |
| Service restarts on macOS | launchd has no declarative restart API |
| Dev repos `git clone` | Live checkouts required for development workflow |
| SOPS decryption at runtime | Secrets must be decrypted at service start |
| Jellyfin/Plex API calls | Runtime service integration, not provisioning |
| Package manager installs (Bun, CargoBinstall, UV, Rustup, Scoop) | These ARE the declarative mechanism on their respective platforms |
| `update.sh` / `check.sh` API queries | Dev-time tools, not activation runtime |
| Log dirs activation (`activation.nix`) | Activation ordering constraint (alphabetical, not dependency-based) prevents `systemd LogsDirectory` from replacing activation-time creation |
| Pwsh module installs (`pwsh.nix`) | Test isolation requires runtime install/teardown; declarative approach cannot express cleanup |
| Android image downloads (`VMAndroid.ps1`, `Invoke-AndroidConfig.ps1`) | Dynamic URLs from latest releases; pre-fetch requires URL pinning in lockfile |
| Ollama model pulls (`Invoke-AISync.ps1`) | Inherently dynamic/user-choice |
| Wi-Fi MAC randomization (`Sync-WifiMacRandomization.ps1`) | Registry path contains runtime-discovered adapter GUIDs; DSC requires static paths |
| PATH management (`Sync-UserPath.ps1`) | Read-modify-write cycle with `WM_SETTINGCHANGE` broadcast via P/Invoke; DSC cannot handle broadcast or reconstruct |
| Firewall per-rule control (`Sync-OpenSSHServer.ps1`, `Sync-WindowsRDP.ps1`) | `Microsoft.Windows.Settings/Firewall` only supports global on/off, not per-rule control |
| CamillaDSP/Heartbeat scheduled tasks | Dynamic arguments (port from `services.json`, config path) cannot be expressed in static DSC |
| Cloud Drive Catalog scheduled tasks | Per-mount dynamic args cannot be expressed in static DSC |
| QtPass config (`Sync-QtPassConfig.ps1`) | Registry hive load/unload for non-current-user profiles. DSC `RegistryValue` only targets the running user's hive, cannot write to another user's registry without hive load/unload logic. |
| Caddy config generation (`Sync-CaddyService.ps1`) | Generates Caddyfile from `services.json` at runtime. NixOS does this declaratively via `services.caddy.virtualHosts`, but merging the two implementations requires a shared Nix module that both hosts consume. Significant refactoring for no practical benefit. |
| Source build git clone (`Invoke-SourceBuild.ps1`) | Source builds need full git history for submodules. Vendoring tarballs via `pkgs.fetchFromGitHub` does not include `.git/` or submodule content. |

## Cross-platform parity matrix

Current declarative status per host for key infrastructure features:

| Feature | macOS | NixOS | Windows |
|---------|-------|-------|--------|
| Caddy config | launchd plist | NixOS Caddyfile (declarative) | PowerShell generation (imperative) |
| Scheduled tasks | launchd plist (declarative) | systemd timer (declarative) | DSC `scheduler.dsc.yml` + `scheduler-user.dsc.yml` (declarative) + PowerShell verification |
| Firewall rules | — (no firewall svc) | nftables (declarative) | DSC global toggle + PowerShell per-rule (imperative — DSC lacks per-rule control) |
| Static registry values | — | — | DSC-convertible (PowerPolicy) + justified imperative (Wi-Fi MAC, PATH) |
| Log dirs | mkdir (imperative) | mkdir activation + systemd (imperative — activation ordering constraint) | mkdir (imperative) |
| State dirs | mkdir (imperative) | `StateDirectory` (partial — redis only) | mkdir (imperative) |
| Runtime downloads | — | — | Pre-fetchable via `vendor-assets` (SteamCMD, CamillaDSP/GUI) + justified imperative (Android, Ollama) |
| Zsh completions | Runtime activation (imperative) | Runtime activation (imperative — deferred build-time) | — |
| Pwsh modules | — | — | Runtime install (imperative — test isolation) |
| Jellyfin API | — | — | Justified imperative (runtime API) |
| Vendor assets | Nix derivations (declarative) | Nix derivations (declarative) | `vendor-assets` flake output + `-VendorDir` param (partially wired) |

## Host vs platform naming

Three-layer model (Host → Platform → Implementation), decision tree, canonical helpers, and SSOT files are in `host-platform-naming.reference.md`. Key rule: host keys for physical machine identity, platform keys for OS-family semantics, never mix.

## Cross-surface identifier mapping

Same step named across five surfaces (Nix activation, DSC, PowerShell, apply function, stage label). Full mapping table, worked examples, and gap documentation are in `host-platform-naming.reference.md`.
