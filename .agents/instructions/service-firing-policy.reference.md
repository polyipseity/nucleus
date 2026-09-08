---
description: "Reference: service firing policy, platform templates, persistent daemon registry, and periodic oneshot classification. Read on demand when adding, modifying, or reviewing nucleus services."
name: "Service Firing Policy Reference"
---

# Service firing policy reference

## Default templates per platform

| | Persistent daemon (auto-start + crash recovery) | Periodic oneshot (timer-triggered, exit between runs) |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| **macOS launchd** | `RunAtLoad = true; KeepAlive = true;` | `StartInterval` or `StartCalendarInterval`; `KeepAlive = false` |
| **NixOS systemd** | `wantedBy = ["multi-user.target"]` (system) / `["default.target"]` (user); `Restart = "always"` | `systemd.timers` (calendar/`OnUnitActiveSec`) + `Type = "oneshot"` service |
| **Windows** | SCM: `StartType = Automatic`; scheduled task: `AtLogOn`/`AtStartup`. Internal `while ($true)` loop for keepalive. | Scheduled task: calendar trigger or `Once` + `Repetition` |

## Persistent daemons (default)

| Service | macOS | NixOS | Windows |
| ------------------------- | ------------------------------------------- | ------------------------- | ---------------------- |
| `betterdisplay-heartbeat` | launchd `agent`, user | — (N/A) | — (N/A) |
| `caddy` | launchd `daemon`, system | SCM | SCM |
| `camilladsp` | launchd `daemon`, system | systemd `service`, system | scheduled task, user |
| `camilladsp-heartbeat` | launchd `agent`, user | systemd `service`, system | scheduled task, user |
| `camillagui-backend` | launchd `daemon`, system | systemd `service`, system | scheduled task, user |
| `cloud-drive` | launchd `agent`, user | systemd `service`, user | scheduled task, user |
| `discord-music-rpc` | launchd `agent`, user | systemd `service`, user | scheduled task, user |
| `jellyfin` | launchd `daemon`, system | systemd `service`, system | SCM |
| `linux-builder` | launchd `daemon`, system | — (N/A) | — (N/A) |
| `litellm` | launchd `daemon`, system | systemd `service`, system | SCM |
| `ollama` | launchd `daemon`, system | systemd `service`, system | SCM |
| `rdp` | — (N/A) | — (N/A) | SCM |
| `service-watchdog` | launchd `daemon`, system | systemd `service`, system | scheduled task, system |
| `service-watchdog-user` | launchd `agent`, user | — (N/A) | — (N/A) |
| `ssh-agent` | launchd `agent`, user (built-in) | systemd `service`, user | SCM |
| `sshd` | launchd `daemon`, system (socket-activated) | systemd `service`, system | SCM |

## Periodic oneshots (exceptions)

| Service | macOS | NixOS | Windows | Rationale |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------ | ---------------------------------- | -------- |
| `gc-weekly` | launchd `daemon`, StartCalendarInterval (Sun 12:00) | systemd `timer`, system (Sun 12:00, `Persistent=true`) | scheduled task (Weekly, Sun 12:00) | Full `gc.sh` as root; user homedir via `sudo -u` |
| `nix-index-update` | launchd `agent`, StartCalendarInterval (daily 12:00) | systemd `timer`, user (daily 12:00, `Persistent=true`) | — (N/A) | Nix ecosystem only |
| `dev-ds-store-gc` | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A) | — (N/A) | macOS `.DS_Store` cleanup |
| `dev-spotlight-exclusions` | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A) | — (N/A) | macOS Spotlight metadata |
| `icloud-exclusions` | launchd `agent`, StartInterval=3600 | — (N/A) | — (N/A) | macOS iCloud xattr drift |

`gc-weekly` log overlap with daily `log-gc-user`/`log-gc-system` is intentional and idempotent. `duperemove` (NixOS only): weekly btrfs dedup on `/nix/store`.

## Internal loop pattern

Persistent daemons needing periodic work use internal sleep loops instead of platform timers. Why: platform timers become crash recovery only; fixes Windows `Duration` cap (P1D stopped repeating after 24 h).

```bash
# POSIX
while true; do
  do_work "$@"
  sleep "$INTERVAL"
done
```

```powershell
# Windows
while ($true) {
  Do-Work
  Start-Seconds -Seconds $Interval
}
```

## Interval configuration

| Service | Interval |
| --- | --- |
| `camilladsp-heartbeat` | 5 s base, exponential backoff to 300 s max (`min(current × 2, max)`, reset on success) |
| `service-watchdog` | 300 s fixed (system scope) |
| `service-watchdog-user` | 300 s fixed (user scope) |
| `betterdisplay-heartbeat` | 30 s fixed |

## macOS-only services

| Service | Reason |
| -------------------------- | ------ |
| `betterdisplay-heartbeat` | macOS-only virtual screen app |
| `dev-ds-store-gc` | `.DS_Store` is Finder/Spotlight convention |
| `dev-spotlight-exclusions` | `.metadata_never_index` is macOS filesystem attr |
| `icloud-exclusions` | `com.apple.fileprovider.ignore#P` xattr is macOS-only |
| `gui-env` | `launchctl setenv` + `launchctl config user path`; login-time coverage |
| `linux-builder` | Nix Linux builder VM; NixOS runs Linux natively |

POSIX-only: `nix-index-update` — Nix ecosystem only; Windows uses Scoop.

## ssh-agent and sshd

| Host | ssh-agent | sshd |
| ----------- | ------- | ---- |
| **macOS** | Built-in `com.openssh.ssh-agent` launchd user agent | Built-in `com.openssh.sshd` launchd daemon (socket-activated) |
| **NixOS** | `programs.ssh.startAgent = true` (systemd user service) | `services.openssh.enable = true` (systemd system service) |
| **Windows** | Built-in `ssh-agent` SCM service | Built-in `sshd` SCM service (WinGet) |
