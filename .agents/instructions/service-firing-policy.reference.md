---
description: "Reference: service firing policy, platform templates, persistent daemon registry, and periodic oneshot classification. Read on demand when adding, modifying, or reviewing nucleus services."
name: "Service Firing Policy Reference"
---

# Service firing policy reference

Per-host mechanism, scope, and unit path live in `src/modules/services.json`. Read them there; this file only classifies services by how they fire and records the rules the JSON cannot express.

## Default templates per platform

| | Persistent daemon (auto-start + crash recovery) | Periodic oneshot (timer-triggered, exit between runs) |
| ----------------- | --------------------------------------------------------- | --------------------------------------------------------- |
| **macOS launchd** | `RunAtLoad = true; KeepAlive = true;` | `StartInterval` or `StartCalendarInterval`; `KeepAlive = false` |
| **NixOS systemd** | `wantedBy = ["multi-user.target"]` (system) / `["default.target"]` (user); `Restart = "always"` | `systemd.timers` (calendar/`OnUnitActiveSec`) + `Type = "oneshot"` service |
| **Windows** | SCM: `StartType = Automatic`; scheduled task: `AtLogOn`/`AtStartup`. Internal `while ($true)` loop for keepalive. | Scheduled task: calendar trigger or `Once` + `Repetition` |

## Persistent daemons (default)

`betterdisplay-heartbeat`, `caddy`, `camilladsp`, `camilladsp-heartbeat`, `camillagui-backend`, `cloud-drive`, `discord-music-rpc`, `hermes-agent`, `jellyfin`, `linux-builder`, `litellm`, `ollama`, `rdp`, `redis`, `service-watchdog`, `service-watchdog-user`, `ssh-agent`, `sshd`.

Everything not in the oneshot list below fires this way, so a new service defaults to a persistent daemon.

## Periodic oneshots (exceptions)

| Service | Cadence | Why not a daemon |
| --- | --- | --- |
| `gc-weekly` | `StartInterval=86400`, Sun 12:00, `Persistent=true` | full `gc.sh` as root plus the user homedir via `sudo -u` |
| `log-gc-system` | `StartInterval=86400`, daily 12:00 | system log rotation of root-owned logs |
| `log-gc-user` | `StartInterval=86400`, daily 12:00 | user log rotation |
| `nix-index-update` | `StartCalendarInterval`, daily 12:00 | Nix ecosystem only; Windows uses Scoop |
| `sccache-gc` | `StartCalendarInterval`, daily 12:00 | a cache clear takes seconds and needs no crash recovery |
| `ds-store-gc` | `StartCalendarInterval`, daily 12:00 | dev-tree cleanup, nothing to keep alive |
| `spotlight-exclusions` | `StartCalendarInterval`, daily 12:00 | dev-tree cleanup, nothing to keep alive |
| `icloud-exclusions` | `StartInterval=3600` | macOS iCloud xattr drift |
| `gui-env` | `RunAtLoad` | login one-shot; the values it exports are what login needs, not a process |

`gc-weekly` overlapping the daily log GCs is intentional and idempotent. `duperemove` is NixOS-only and runs weekly over `/nix/store`.

## Internal loop pattern

A persistent daemon that also needs periodic work uses an internal sleep loop instead of a platform timer. Platform timers give crash recovery only, and an internal loop gets around the Windows scheduled-task `Duration` cap, where a `P1D` repetition stopped repeating after 24 hours.

## Interval configuration

| Service | Interval |
| --- | --- |
| `camilladsp-heartbeat` | 5 s base, exponential backoff to 300 s max (`min(current × 2, max)`, reset on success) |
| `service-watchdog` | 300 s fixed (system scope) |
| `service-watchdog-user` | 300 s fixed (user scope) |
| `betterdisplay-heartbeat` | 60 s fixed |

## macOS-only services

| Service | Reason |
| -------------------------- | ------ |
| `betterdisplay-heartbeat` | macOS-only virtual screen app |
| `ds-store-gc` | Finder creates the files it removes |
| `spotlight-exclusions` | `.metadata_never_index` is a Spotlight convention |
| `gui-env` | `launchctl setenv` plus `launchctl config user path`; needs login-time coverage |
| `icloud-exclusions` | `com.apple.fileprevider.ignore#P` xattr is macOS-only |
| `linux-builder` | Nix Linux builder VM; NixOS builds Linux natively |

`nix-index-update` is POSIX-only: Nix ecosystem, no Windows equivalent.

## ssh-agent and sshd

| Host | ssh-agent | sshd |
| ----------- | ------- | ---- |
| **macOS** | Built-in `com.openssh.ssh-agent` launchd user agent | Built-in `com.openssh.sshd` launchd daemon (socket-activated) |
| **NixOS** | `programs.ssh.startAgent = true` (systemd user service) | `services.openssh.enable = true` (systemd system service) |
| **Windows** | Built-in `ssh-agent` SCM service | Built-in `sshd` SCM service (WinGet) |
