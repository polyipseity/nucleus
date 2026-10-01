---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

Same capability on every host. Reusable behavior goes in a shared module rather than a per-host special case: POSIX is bash under `src/scripts/`, Windows is PowerShell under `src/platforms/Windows/modules/`, and no Windows runtime code may name a `.sh` path. A platform difference needs a `# WHY:`.

## Scope

Evaluate macOS (`src/hosts/MacBook/`), NixOS (`src/hosts/NixOS/`), and Windows (`src/hosts/Windows/` plus `src/platforms/Windows/modules/`) before writing, and implement every applicable host in the same change. When parity debt cannot be paid, say which of the three states applies: implemented now, already in parity, or not practical yet with a `# WHY:` in code. Sweep the whole surface: packages and tools, shell and dev tooling, security, desktop and UI, remote access, secrets, editor, git and signing, power and network, automation.

Desktop and UI work should reduce persistent chrome where keyboard workflows still cover it, and keep high-signal visibility defaults unless a host constraint forces the loss. State the tradeoff and the remaining access path in the DSC `directives.description:` or the equivalent note.

## Where to implement

POSIX-shared behavior belongs in `src/modules/*.nix`. On Windows, a DSC resource wins when one covers the state; otherwise use `src/platforms/Windows/modules/*.ps1` and keep `apply.ps1` orchestration-only. Imperative Windows parity needs a cleanup path as well as a config path, otherwise disabling it leaves state behind.

## Script deduplication

A host-specific script earns its name only if the feature is genuinely host-specific. Anything applicable to both POSIX hosts goes in a shared subdirectory, and when both macOS and NixOS need the same feature, merge the bodies with `builtins.replaceStrings` or a `case "$(uname)"` branch instead of keeping prefixes and twins. A config with a native extension point (direnv `lib/*.sh`, for example) uses the host-specific `lib/` convention from `app-config-policy.instructions.md`.

## Imperative recovery safety (Windows)

Config and deconfig paths both need: touch only declaratively managed blocks, keys, and files; stop when ownership or preconditions are ambiguous; converge idempotently with no duplicated managed content; clean up idempotently, removing only managed state and no-oping when it is already gone; and an explicit enable/disable toggle wired in `apply.ps1`.

macOS and NixOS need no equivalent: Nix removes the unit files on re-apply. Windows needs it by hand, because nothing else does. `Sync-*Service.ps1` for SCM services (Caddy, LiteLLM) and `Unregister-ScheduledTask` in the `Sync-*` task modules. A new Windows module must implement both paths, and a failed start warns without aborting activation.

## Centralized service refresh

Every kill, refresh, and restart goes through a library: `refresh_*` in `src/scripts/lib/macos-launch-services.sh` on macOS, `Set-NucleusService.ps1` on Windows. Never inline `killall` or `Stop-Service`. macOS activation blocks call the library through a wrapper script under `src/platforms/macOS/scripts/` rather than sourcing it inline. Restart each daemon at most once per activation.

Firing defaults to a persistent daemon with auto-start and crash recovery; periodic oneshots are the exception, and `service-firing-policy.reference.md` holds the classification. No explicit rate limiting, since platform defaults cover it.

## Package parity

A cross-host tool lands in `core.nix` for POSIX and `system-packages.dsc.yml` for Windows in the same change. A tool available from both nixpkgs and Homebrew is declared once in `managedPackages` in `core.nix`, never spread across host files or duplicated in `NixOS/desktop.nix`. Windows source builds pin a commit hash and document it in `Build-<Tool>.ps1`.

Secrets and wallpapers keep the same shape on every host: `secrets.nix` plus `materialize-user-secrets.sh` on POSIX, `Sync-UserSecret.ps1` and `Sync-SecretFile.ps1` on Windows, `wallpapers.nix` versus `Sync-WallpaperInventory.ps1` and `user.dsc.yml`. Preserve the existing stale cleanup rules. Cloud drives: `cloud-drives-and-finder.instructions.md`.

## GC and retention

Timing values live at their point of use, so a change edits the source file and never a separate manifest. Override precedence: CLI flag, then per-tool env var, then master flag or env, then the Nix config default, then `7d` / `7`.

## Provisioned symlinks

Every provisioned symlink must be writable and delete-protected where the platform allows it: `chflags uchg` on macOS, `icacls /deny` on Windows. A user-scope Linux activation cannot set the immutable flag (`chattr` needs `CAP_LINUX_IMMUTABLE`, see `chattr(1)`), so NixOS enforces the same contract by detection instead: check step 13 (`run_method1_symlink_resolution`) and `home.activation.verify-managed-symlink-paths`. The platforms that can prevent removal still warn on failure rather than aborting.

Read-only is required when the target lives in the Nix store, because store content is immutable, and Windows mirrors the POSIX writability semantics. Any deviation needs a `# WHY:`.

`macos-symlink-farm.sh` manages the `/usr/local/bin` entries for Nix store paths from the `__nucleus_symlink_farm` env var that `src/hosts/MacBook/activation.nix` generates. It only ever removes symlinks, never regular files.

## Imperative code that belongs there

Imperative steps are by design, not a leftover: bootstrap curl before Nix exists; `defaults write` and macOS restarts, which have no declarative or launchd API; `git clone`, SOPS decryption, and API calls that need live state; package managers, which have a declarative mechanism per platform; log dirs, PowerShell modules, and Android images, which depend on ordering or dynamic URLs; Wi-Fi MAC, PATH, and firewall values, which are runtime GUIDs, broadcasts, or DSC-global-only; CamillaDSP, heartbeat, and cloud-drive tasks, whose ports and config are dynamic; and QtPass, Caddy config, and source builds, which need HKCU hives, runtime builds, or git history.

## Before merging

All three hosts evaluated, every exception justified with a `# WHY:`, shared logic extracted, and the matching instructions file updated.
