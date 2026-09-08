---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

## Goal

Parity-first: same capability on every host. Reusable behavior in shared modules; avoid special-casing. POSIX uses bash, Windows uses PowerShell — never mix. Differences require WHY comments.

## Implementation pattern

- POSIX (macOS + NixOS): `scripts/*.sh` or `src/scripts/**/*.sh`
- Windows: `scripts/*.ps1` or `src/platforms/Windows/modules/**/*.ps1`
- Shared content: single file in `src/scripts/` per `embedded-content.instructions.md`
- Windows prohibition: no `.sh` paths from Windows runtime code

## Feature scope triage

Evaluate all three hosts before writing code: macOS (`src/hosts/MacBook/` + shared), NixOS (`src/hosts/NixOS/` + shared), Windows (`src/hosts/Windows/` + `src/platforms/Windows/modules/`). Implement all applicable hosts in the same change.

When reducing parity debt, evaluate each feature per host: implement parity now, already in parity, or not practical yet (WHY in code). Review: packages/tools, shell/dev workflow, security posture, desktop/UI, remote-access, secrets, editor experience, git/signing, power/network, automation hooks.

Desktop/UI: prefer reducing persistent chrome when keyboard/command workflows remain. Preserve high-signal visibility defaults (hidden files, file extensions, status/path bars) unless a host constraint prevents it.

### Host-specific lib/ pattern

When a config has a native extension-point that auto-loads overrides (e.g. direnv `lib/*.sh`), use the host-specific lib/ subdirectory convention from `app-config-policy.instructions.md`. Avoids `if-else` branches and dead platform-specific code.

## Where to implement

- **POSIX shared** (macOS + NixOS): `src/modules/*.nix`.
- **Windows declarative**: DSC YAML (`system.dsc.yml`, `system-packages.dsc.yml`, `user.dsc.yml`, `user-env.dsc.yml`, `user-context.dsc.yml`) when a WinGet DSC resource covers it.
- **Windows imperative**: `src/platforms/Windows/modules/*.ps1`; keep `apply.ps1` orchestration-only.
- Imperative Windows parity needs explicit cleanup/deconfiguration path for safe disable.

## Imperative recovery safety (Windows)

Imperative Windows parity requires in both config and deconfig paths:

- **Managed-scope only**: touch only declaratively managed blocks/keys/files.
- **Fail-fast on unsafe state**: stop when ownership or preconditions are ambiguous.
- **Idempotent convergence**: no duplicate managed content on repeated apply.
- **Idempotent cleanup**: disable removes only managed state; no-op when already absent.
- **Explicit toggle**: wire enable/disable in `apply.ps1` with cleanup.

## Service lifecycle cleanup

- **macOS/NixOS**: automatic — Nix removes the unit file on re-apply.
- **Windows SCM** (Caddy, LiteLLM): `Sync-*Service.ps1` implements `Stop-Service` + `sc.exe delete` when `-Enabled:$false`.
- **Windows scheduled tasks**: each `Sync-*` module calls `Unregister-ScheduledTask` when disabled.

New Windows service modules must implement both enable and disable paths. Verify disable fully removes managed state.

Failed service starts emit a warning but do not abort activation. Watchdog handles retries.

## Service firing policy

Default: persistent daemon (auto-start + crash recovery). Periodic oneshots are explicit exceptions. No explicit rate-limiting — platform defaults suffice. Full details in `service-firing-policy.reference.md`.

## Package parity rules

- Cross-host CLI tools: add to `src/modules/core.nix` (POSIX) and `src/hosts/Windows/system-packages.dsc.yml` (Windows) in the same change.
- Dual nixpkgs + Homebrew packages go to `managedPackages` in `core.nix`, not spread across host files. See `package-installation-scope.instructions.md`.
- Remove duplicates from `src/hosts/NixOS/desktop.nix` when `core.nix` `sharedPackages` already covers the package.
- Windows source builds: pin by commit hash. Document steps in `Build-<Tool>.ps1` under `src/platforms/Windows/modules/`.

## Secrets and wallpaper parity

- Secrets: POSIX `src/modules/secrets.nix` + `materialize-user-secrets.sh`; Windows `Sync-UserSecret.ps1` / `Sync-SecretFile.ps1` via `apply.ps1`.
- Wallpapers: POSIX `src/modules/wallpapers.nix`; Windows `Sync-WallpaperInventory.ps1` + `user.dsc.yml`.
- Preserve stale cleanup rules on every host.

## Cloud-drive parity

See `cloud-drives-and-finder.instructions.md`. Key: mounts/replicas parity-first, managed paths as real directories (macOS-only iCloud exception documented there), no push/bisync for replicas.

## Cross-platform script deduplication

Host-specific scripts (`src/hosts/<Host>/scripts/`) must implement genuinely host-specific features. If applicable to any POSIX host, use a shared subdirectory (`services/`, `configs/`, `packages/`, etc.).

When both macOS and NixOS have host-specific implementations of the same feature, merge into one POSIX-compatible script via `builtins.replaceStrings` token substitution or `case "$(uname)"` dispatch. Drop the `macos-`/`nixos-` prefix. Delete originals after merge.

## Allowed platform-specific exceptions

Single-host only when the feature depends on platform-specific primitives (macOS defaults domains, NixOS kernel modules, Windows registry/DSC). WHY comment in code required. If the exception masks controls, the WHY must explain the tradeoff and name the alternate access path.

## Pre-merge parity checklist

- All three hosts evaluated; multi-host implementation where practical.
- Exceptions have WHY comments.
- Shared logic extracted into shared modules.
- Related instructions updated when invariants changed.

## GC and retention policy

Timing values live at their point of use. Change them in the source file listed below, not a separate manifest.

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

Override precedence: CLI flag > per-tool env var > master flag/env > Nix config default > `7d` / `7`.

## Provisioned symlink policy

Every provisioned symlink must be writable AND delete-protected (`chflags uchg` macOS, `chattr +i` Linux, `icacls /deny` Windows). Best-effort with warning on failure.

Read-only exception: symlink MUST be read-only when target is in the Nix store (immutable content). On Windows, mirror POSIX writability semantics. Deviations require `# WHY:` comment.

### macOS /usr/local/bin symlink farm

`macos-symlink-farm.sh` manages `/usr/local/bin` symlinks for Nix store entries. Reads `__nucleus_symlink_farm` (space-separated `target->name` pairs). Only removes symlinks (`-L`), never regular files. Env var generated in `src/hosts/MacBook/activation.nix`.

## By-design imperative patterns

| Pattern | Why imperative |
|---------|---------------|
| Bootstrap curl | Before Nix installed |
| `defaults write` / macOS restarts | No declarative API; no launchd restart API |
| `git clone`, SOPS, Jellyfin/Plex API | Runtime requirements (live checkouts, decryption, service queries) |
| Package managers (Scoop/bun/cargo-binstall/uv/rustup) | Declarative mechanism on each platform |
| `update.sh`/`check.sh` queries | Dev-time, not activation |
| Log dirs, Pwsh modules, Android images | Ordering/DRY-constraint, Nix store read-only, dynamic URLs |
| Ollama model pulls | User choice, not provisioning |
| Wi-Fi MAC, PATH, Firewall per-rule | Runtime GUIDs, broadcast/DSC gap, DSC global-only |
| CamillaDSP/Heartbeat/Cloud Drive tasks | Dynamic port/config/args from runtime state |
| QtPass config (`HKCU` hives) | DSC targets only running user |
| Caddy config, Source builds | Runtime `services.json` build, git history needed for submodules |

## Cross-platform parity matrix

| Feature | macOS | NixOS | Windows |
|---------|-------|-------|--------|
| Caddy config | launchd plist | NixOS Caddyfile | PowerShell generation |
| Scheduled tasks | launchd plist | systemd timer | DSC scheduler + PS verification |
| Firewall rules | — | nftables | DSC global toggle + PS per-rule |
| Registry values | — | — | DSC + justified imperative |
| Log/state dirs | mkdir | mkdir + `StateDirectory` (partial) | mkdir |
| Runtime downloads | — | — | Justified imperative |
| Zsh completions | Activation | Activation | — |
| Vendor assets | Nix derivations | Nix derivations | Download at setup (no Nix) |
