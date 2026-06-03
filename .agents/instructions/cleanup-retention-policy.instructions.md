---
description: "Use when reviewing or modifying cleanup/retention timings in Nix modules, GC scripts, or host DSC configs. Single source of truth for all expiry intervals."
name: "Cleanup and Retention Policy"
applyTo: "src/**/*.nix, scripts/gc.*, src/hosts/Windows/**/*.yml"
---

# Cleanup and Retention Policy

## Time-Based Retention

| Duration           | What it controls                                                        | File                                                        | Mechanism                                                                      |
| ------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **7 days**         | Nix store garbage collection (`--delete-older-than 7d`)                 | `src/modules/posix-base.nix`                                | `nix.gc.options` (NixOS) / launchd `ProgramArguments` (macOS)                  |
| **7 days**         | Home Manager generation expiry (`-7 days`)                              | `scripts/gc.sh`                                             | `home-manager expire-generations "-7 days"`                                    |
| **30 days**        | macOS Finder Trash auto-prune (Apple default, non-configurable boolean) | `src/hosts/MacBook/defaults.nix`                            | `FXRemoveOldTrashItems = true`                                                 |
| **30 days**        | Windows Recycle Bin auto-purge (Storage Sense)                          | `src/hosts/Windows/system.dsc.yml`                          | Storage Sense policy registry (`ConfigStorageSenseRecycleBinCleanupThreshold`) |
| **1 hour**         | rclone VFS cache max age (`--vfs-cache-max-age 1h`)                     | `src/modules/cloud-drives.nix`                              | rclone mount flag                                                              |
| **5 minutes**      | rclone directory cache TTL (`--dir-cache-time 5m`)                      | `src/modules/cloud-drives.nix`                              | rclone mount flag                                                              |
| **1 minute**       | rclone remote change polling interval (`--poll-interval 1m`)            | `src/modules/cloud-drives.nix`                              | rclone mount flag                                                              |
| **5 minutes**      | sudo credential caching timeout (`timestamp_timeout=5`)                 | `src/modules/posix-security.nix`                            | `security.sudo.extraConfig`                                                    |
| **60 seconds**     | Windows screen saver idle timeout before lock                           | `src/hosts/Windows/user.dsc.yml`                            | `ScreenSaveTimeOut = "60"`                                                     |
| **~1 minute**      | GNOME display idle → lock chain (idle-delay=60s, lock-delay=0)          | `src/modules/linux.nix`                                     | `idle-delay = 60`, `lock-delay = 0`                                            |
| **Immediate (0s)** | macOS screensaver password delay                                        | `src/hosts/MacBook/defaults.nix`                            | `askForPasswordDelay = 0`                                                      |
| **30 seconds**     | BetterDisplay heartbeat poll interval                                   | `src/modules/macos.nix`                                     | LaunchAgent KeepAlive poll                                                     |
| **30 seconds**     | rclone sync operation timeout                                           | `src/hosts/Windows/modules/system/Invoke-ReplicaSync.ps1`   | `--timeout 30s`                                                                |
| **10 seconds**     | rclone sync connection timeout                                          | same file                                                   | `--contimeout 10s`                                                             |
| **10 seconds**     | Jellyfin REST API timeout                                               | `src/hosts/Windows/modules/system/Sync-JellyfinAccount.ps1` | `TimeoutSec = 10`                                                              |
| **5 seconds**      | VS Code extensions DB SQLite lock timeout                               | `src/modules/editors.nix`                                   | `sqlite3.connect(timeout=5)`                                                   |
| **30 seconds**     | Picard network transfer timeout                                         | `src/modules/configs/picard/Picard.ini`                     | `network_transfer_timeout_seconds=30`                                          |
| **150 seconds**    | VM setup network wait timeout                                           | `src/hosts/Windows/modules/system/Invoke-VMSetup.ps1`       | `$TimeoutSeconds = 150`                                                        |
| **60 seconds**     | Ollama server readiness wait                                            | `scripts/ai-sync.sh`                                        | `--server-ready-timeout-seconds 60`                                            |
| **0 seconds**      | Ollama readiness wait during GC                                         | `scripts/gc.sh`                                             | `--server-ready-timeout-seconds 0`                                             |
| **2 seconds**      | Ollama readiness poll interval                                          | `scripts/ai-sync.sh`                                        | `--server-ready-poll-seconds 2`                                                |

## Scheduled Timer Frequencies

> **All times are local time** unless explicitly noted otherwise.

| Schedule                    | What                                                          | Hosts                 | File / Mechanism                                                                        |
| --------------------------- | ------------------------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------- |
| **Daily 12:00**             | Nix store GC                                                  | NixOS, macOS          | `src/modules/posix-base.nix`                                                            |
| **Daily 12:00**             | nix-index database rebuild                                    | macOS, NixOS          | `src/modules/macos.nix` (launchd), `src/modules/linux.nix` (systemd)                    |
| **Daily 12:00**             | `.DS_Store` + Spotlight + iCloud exclusion refresh            | macOS                 | `src/modules/macos.nix` (launchd)                                                       |
| **Daily 12:00**             | Replica sync fallback                                         | macOS, NixOS, Windows | `src/modules/cloud-drives.nix`, `Sync-ReplicaSyncScheduledTask.ps1`                     |
| **Daily 12:00**             | Windows Recycle Bin 30-day auto-purge (Storage Sense)         | Windows               | Storage Sense registry policy (`HKLM\Software\Policies\Microsoft\Windows\StorageSense`) |
| **Weekly Sunday 12:00**     | GC (full: Nix + HM + wallpapers + tool caches + Ollama + VMs) | macOS, NixOS, Windows | `src/modules/macos.nix`, `src/modules/linux.nix`, `src/hosts/Windows/system.dsc.yml`    |
| **At logon + 1min restart** | LiteLLM proxy                                                 | Windows               | `Sync-LiteLLMScheduledTask.ps1`                                                         |
| **Every activation**        | Homebrew zap + VS Code extensions prune + agent skills prune  | All POSIX             | Various module files                                                                    |

## Declarative-Diff Cleanups (Not Time-Based)

| What it prunes                               | Source of truth              | Files                             |
| -------------------------------------------- | ---------------------------- | --------------------------------- |
| Wallpaper decrypted copies                   | `.sops` source files in repo | `scripts/gc.sh`, `scripts/gc.ps1` |
| Ollama models                                | `src/modules/ai/models.json` | `Invoke-AISync -PruneOnly`        |
| VM artifacts (except Windows installer ISOs) | `src/modules/VMs.json`       | `scripts/gc.sh`, `scripts/gc.ps1` |
| VS Code extensions                           | Nix-managed extension set    | `src/modules/editors.nix`         |
| Agent/Skills                                 | Declared skills inventory    | `src/modules/agents.nix`          |
| GPG managed keys                             | SOPS secret key fingerprint  | `src/modules/secrets.nix`         |
| Homebrew packages                            | Nix-declared formulae/casks  | `src/hosts/MacBook/homebrew.nix`  |
| Tool caches (bun, cargo, rustup, uv, direnv) | N/A (unconditional clear)    | `scripts/gc.sh`, `scripts/gc.ps1` |
| Scoop old versions                           | N/A (Scoop's own cleanup)    | `scripts/gc.ps1`                  |

## Authoring Rule

- Update this file when changing any timing value. Keep the tables in sync with the actual code — if you change a duration in a module, update this file in the same commit.
