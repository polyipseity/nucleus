---
description: "Reference: service firing policy, platform templates, persistent daemon registry, and periodic oneshot classification. Read on demand when adding, modifying, or reviewing nucleus services."
name: "Service Firing Policy Reference"
---

# Service firing policy reference

## Default policy: persistent daemon

All nucleus-managed services use persistent-daemon semantics by default: auto-start on boot/login and auto-restart on crash. This gives a consistent service lifecycle across all hosts with no manual recovery needed after transient failures.

### Default templates per platform

| | Persistent daemon (auto-start + crash recovery) | Periodic oneshot (timer-triggered, exit between runs) |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| **macOS launchd** | `RunAtLoad = true; KeepAlive = true;` | `StartInterval` or `StartCalendarInterval`; `KeepAlive = false`; `RunAtLoad = false` (or `true` if an immediate first tick is desired) |
| **NixOS systemd** | `wantedBy = ["multi-user.target"]` (system) or `["default.target"]` (user); `serviceConfig.Restart = "always"` | `systemd.timers` (calendar or `OnUnitActiveSec`) + `Type = "oneshot"` service |
| **Windows** | SCM: `StartType = Automatic`; scheduled task: `AtLogOn` (user) or `AtStartup` (system) with `AllowStartIfOnBatteries`, `DontStopIfGoingOnBatteries`, `StartWhenAvailable`. Scripts with internal `while ($true)` loop for keepalive. | Scheduled task with calendar trigger or `Once` + `Repetition` |

### Persistent daemons (default)

| Service | macOS | NixOS | Windows |
| ------------------------- | ------------------------------------------- | ------------------------- | ---------------------- |
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
| `betterdisplay-heartbeat` | launchd `agent`, user | — (N/A) | — (N/A) |

### Periodic oneshots (exceptions)

| Service | macOS | NixOS | Windows | Rationale |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------ | ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `gc-weekly` | launchd `daemon`, StartCalendarInterval (Sun 12:00) | systemd `timer`, system (Sun 12:00, `Persistent=true`) | scheduled task (Weekly, Sun 12:00) | Runs full `gc.sh` as root; user homedir steps via `sudo -u` |
| `nix-index-update` | launchd `agent`, StartCalendarInterval (daily 12:00) | systemd `timer`, user (daily 12:00, `Persistent=true`) | — (N/A) | Daily rebuild with freshness guard; not applicable on Windows (no nix ecosystem) |
| `dev-ds-store-gc` | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A) | — (N/A) | macOS-only; Finder `.DS_Store` cleanup |
| `dev-spotlight-exclusions` | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A) | — (N/A) | macOS-only; Spotlight metadata markers |
| `icloud-exclusions` | launchd `agent`, StartInterval=3600 | — (N/A) | — (N/A) | macOS-only; iCloud ignore xattr drift correction |

- **`gc-weekly` log overlap:** runs full `gc.sh` including log rotate/expire; daily `log-gc-user` / `log-gc-system` cover the same paths — overlap is intentional and idempotent.
- **`duperemove` (NixOS only):** weekly root `gc.sh` runs btrfs block dedup on `/nix/store` after `nix-collect-garbage`. No macOS/Windows parity — those hosts have no Nix store on btrfs.

### Explicit recovery settings removed

Service configurations do not set explicit rate-limiting or restart-interval settings (`ThrottleInterval` on macOS, `RestartSec` on NixOS, `RestartCount`/`RestartInterval` on Windows). Platform defaults suffice: the internal loop pattern handles keepalive pacing, so the service manager only needs crash recovery (launchd's default throttle is shorter than 30 s; systemd's default `RestartSec` is 100 ms; Windows scheduled tasks do not restart — the internal loop handles keepalive).

### Internal loop pattern (heartbeat and watchdog)

Services that need periodic work but must stay registered as persistent daemons use an internal sleep loop instead of platform timers:

```bash
# POSIX (shell script)
while true; do
  do_work "$@"
  sleep "$INTERVAL"
done
```

```powershell
# Windows (PowerShell)
while ($true) {
  Do-Work
  Start-Seconds -Seconds $Interval
}
```

#### Exponential backoff (camilladsp-heartbeat)

The `camilladsp-heartbeat` script uses exponential backoff instead of a fixed sleep interval. This prevents rapid retry loops when CamillaDSP is down for an extended period (e.g., audio device disconnected, daemon restarting).

- **Base delay**: 5 s
- **Maximum delay**: 300 s
- **Algorithm**: on failure, `sleep = min(current × 2, max)`. On success, reset to base delay immediately.

The service-watchdog and betterdisplay-heartbeat use fixed intervals (300 s and 30 s, respectively) because their work is lightweight and failure recovery does not benefit from backoff.

This pattern applies to:

- `camilladsp-heartbeat` (5 s base, exponential backoff to 300 s max)
- `service-watchdog` (300 s fixed loop, system scope)
- `service-watchdog-user` (300 s fixed loop, user scope)
- `betterdisplay-heartbeat` (30 s fixed loop)

Why this pattern: platform timer mechanisms (StartInterval, systemd timers, scheduled-task repetition) become crash recovery only — the daemon stays "running" instead of repeatedly spawning short-lived processes. Also fixes the Windows scheduled-task `Duration` cap (P1D on the watchdog stopped repeating after 24 h).

## macOS-only services

These services are specific to macOS and have no cross-host equivalent:

| Service | Reason |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `betterdisplay-heartbeat` | BetterDisplay is a macOS-only app for virtual screens |
| `dev-ds-store-gc` | `.DS_Store` is a Finder/Spotlight macOS convention |
| `dev-spotlight-exclusions` | `.metadata_never_index` is a macOS filesystem attribute |
| `icloud-exclusions` | `com.apple.fileprovider.ignore#P` xattr is macOS-only |
| `gui-env` | `macos-gui-env-path` activation step sets all vars via `launchctl setenv` + `launchctl config user path`; one-shot `gui-env` LaunchAgent provides login-time coverage |
| `linux-builder` | Nix Linux builder VM is macOS-specific (NixOS runs Linux natively) |

## POSIX-only services

Services that exist on macOS and NixOS but not on Windows:

| Service | Rationale |
| ------------------ | --------------------------------------------------------------------------------- |
| `nix-index-update` | nix-index is part of the Nix ecosystem; Windows uses Scoop for package management |

## ssh-agent and sshd

All hosts use the OS-native SSH agent and server, with no custom service definitions:

| Host | ssh-agent | sshd |
| ----------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **macOS** | Built-in `com.openssh.ssh-agent` launchd user agent (defined by OS) | Built-in `com.openssh.sshd` launchd system daemon (socket-activated) |
| **NixOS** | `programs.ssh.startAgent = true` (systemd user service) | `services.openssh.enable = true` (systemd system service) |
| **Windows** | Built-in `ssh-agent` SCM service (Windows OpenSSH) | Built-in `sshd` SCM service (Windows OpenSSH, installed via WinGet) |
