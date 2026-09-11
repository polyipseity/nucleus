---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

## Goal

Parity-first: same capability on every host. Reusable behavior in shared modules; avoid special-casing. POSIX uses bash, Windows uses PowerShell — never mix. Differences require WHY comments.

## Implementation pattern

POSIX: `scripts/*.sh` or `src/scripts/**/*.sh`. Windows: `scripts/*.ps1` or `src/platforms/Windows/modules/**/*.ps1`. Shared: single file in `src/scripts/`. No `.sh` paths from Windows runtime code.

## Feature scope triage

Evaluate all three hosts before writing: macOS (`src/hosts/MacBook/`), NixOS (`src/hosts/NixOS/`), Windows (`src/hosts/Windows/` + `src/platforms/Windows/modules/`). Implement all applicable hosts in the same change. When reducing parity debt: implement now, already in parity, or not practical yet (WHY in code). Review areas: packages/tools, shell/dev, security, desktop/UI, remote-access, secrets, editor, git/signing, power/network, automation.

Desktop/UI: prefer reducing persistent chrome when keyboard workflows remain. Preserve high-signal visibility defaults unless a host constraint prevents it.

### Host-specific lib/ pattern

When a config has a native extension-point (e.g. direnv `lib/*.sh`), use the host-specific lib/ convention from `app-config-policy.instructions.md`.

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

- **macOS/NixOS**: automatic — Nix removes unit files on re-apply.
- **Windows SCM** (Caddy, LiteLLM): `Sync-*Service.ps1` implements `Stop-Service` + `sc.exe delete` when disabled.
- **Windows tasks**: `Sync-*` modules call `Unregister-ScheduledTask` when disabled.

New Windows modules must implement enable and disable paths. Failed starts warn but don't abort activation.

## Centralized daemon/service refresh

All killing, refresh, and restart operations must go through centralized library functions: macOS `src/scripts/lib/macos-launch-services.sh` (`refresh_*` functions), Windows `src/platforms/Windows/modules/Set-NucleusService.ps1`. Do not inline killall/Stop-Service commands. For macOS activation blocks, use wrapper scripts under `src/platforms/macOS/scripts/` that source the library and call `refresh_*` functions.

## Service firing policy

Default: persistent daemon (auto-start + crash recovery). Periodic oneshots are explicit exceptions. No explicit rate-limiting — platform defaults suffice. Full details in `service-firing-policy.reference.md`.

## Package parity rules

Cross-host tools: add to `core.nix` (POSIX) and `system-packages.dsc.yml` (Windows) in same change. Dual nixpkgs+Homebrew: use `managedPackages` in `core.nix`, not spread across hosts. Remove duplicates from `NixOS/desktop.nix`. Windows source builds: pin by commit hash, document in `Build-<Tool>.ps1`.

## Secrets and wallpaper parity

Secrets: POSIX `secrets.nix` + `materialize-user-secrets.sh`; Windows `Sync-UserSecret.ps1`/`Sync-SecretFile.ps1`. Wallpapers: POSIX `wallpapers.nix`; Windows `Sync-WallpaperInventory.ps1` + `user.dsc.yml`. Preserve stale cleanup rules.

## Cloud-drive parity

See `cloud-drives-and-finder.instructions.md`. Key: mounts/replicas parity-first, managed paths as real directories (macOS-only iCloud exception documented there), no push/bisync for replicas.

## Cross-platform script deduplication

Host-specific scripts must implement genuinely host-specific features. If applicable to any POSIX host, use a shared subdirectory. When both macOS and NixOS have the same feature, merge via `builtins.replaceStrings` or `case "$(uname)"`. Drop prefixes; delete originals.

## Allowed exceptions and pre-merge checklist

Single-host only for platform-specific primitives (macOS defaults, NixOS kernel modules, Windows registry/DSC). WHY comment required; if masking controls, explain tradeoff and alternate access path. Before merge: all three hosts evaluated, exceptions justified, shared logic extracted, instructions updated.

## GC and retention policy

Timing values live at their point of use. Change them in the source file, not a separate manifest.

Nix store GC: `posix-base.nix`, `nix-store-gc.sh`, `gc.sh`, `gc-options.nix`. macOS: `platforms/macOS/modules/default.nix`, `hosts/MacBook/defaults.nix`. Linux: `platforms/NixOS/modules/default.nix`, `posix-security.nix`. Windows DSC: `system.dsc.yml`, `system-packages.dsc.yml`, `user.dsc.yml`, `user-env.dsc.yml`, `user-context.dsc.yml`, `platforms/Windows/modules/system/*.ps1`. Cloud: `cloud-drives.nix`. AI: `ai-sync.sh`. App-level: `editors.nix`, `picard/Picard.ini`.

Override precedence: CLI flag > per-tool env var > master flag/env > Nix config default > `7d` / `7`.

## Provisioned symlink policy

Every provisioned symlink must be writable AND delete-protected where the platform permits it: `chflags uchg` (macOS) and `icacls /deny` (Windows) prevent removal. Linux cannot, from a user-scope activation — `chattr` requires `CAP_LINUX_IMMUTABLE` (see `chattr(1)`) — so NixOS enforces the same contract by detection: check step 19 (`method-one-symlink-resolution`) plus `home.activation.verify-managed-symlink-paths`. Best-effort with warning on failure applies to the platforms that attempt prevention.

Read-only exception: symlink MUST be read-only when target is in the Nix store (immutable content). On Windows, mirror POSIX writability semantics. Deviations require `# WHY:` comment.

### macOS /usr/local/bin symlink farm

`macos-symlink-farm.sh` manages `/usr/local/bin` symlinks for Nix store entries. Reads `__nucleus_symlink_farm` (space-separated `target->name` pairs). Only removes symlinks (`-L`), never regular files. Env var generated in `src/hosts/MacBook/activation.nix`.

## By-design imperative patterns

| Pattern | Why |
|---------|-----|
| Bootstrap curl | Before Nix installed |
| `defaults write`, macOS restarts | No declarative API, no launchd restart API |
| `git clone`, SOPS, API calls | Runtime (live checkouts, decryption, queries) |
| Package managers | Declarative mechanism on each platform |
| Log dirs, Pwsh modules, Android images | Ordering constraint, Nix store read-only, dynamic URLs |
| Wi-Fi MAC, PATH, Firewall | Runtime GUIDs, broadcast, DSC global-only |
| CamillaDSP/Heartbeat/Cloud Drive tasks | Dynamic port/config/args |
| QtPass, Caddy config, Source builds | HKCU hives, runtime build, git history needed |

## Cross-platform parity matrix

| Feature | macOS | NixOS | Windows |
| --- | --- | --- | --- |
| Caddy | launchd plist | NixOS Caddyfile | PS generation |
| Tasks | launchd plist | systemd timer | DSC + PS verify |
| Firewall | — | nftables | DSC global + PS per-rule |
| Registry | — | — | DSC + imperative |
| Log/state dirs | mkdir | mkdir + `StateDirectory` | mkdir |
| Downloads | — | — | Imperative |
| Completions | Activation | Activation | — |
| Vendor assets | Nix derivations | Nix derivations | Download (no Nix) |
