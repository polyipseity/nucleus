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

## Supervision ownership (audit)

Native supervisors own crash recovery. The watchdog owns liveness probes, repair, and health accounting for supervised managed services. Service scripts own their own work; they must not duplicate watchdog liveness/repair logic or native crash-restart ownership. A second mechanism is allowed only for a distinct duty and must carry an inline `# WHY:` naming that duty.

| Service | macOS | NixOS | Windows | Watchdog | Script loop/restart (audited) | Owner notes |
| --- | --- | --- | --- | --- | --- | --- |
| `betterdisplay-heartbeat` | launchd agent `local.betterdisplay-heartbeat`, `RunAtLoad`+`KeepAlive` (crash recovery) | omitted | omitted | supervised (crash-loop/liveness via watchdog; heartbeat records `svc_health_record_success`) | `src/platforms/macOS/scripts/macos-heartbeat-betterdisplay.sh`: fixed-interval probe loop, records success in health record; no supervisor restart tokens | native=crash recovery, watchdog=loop/liveness accounting, script=probe/converge work |
| `caddy` | launchd daemon `org.nixos.httpsProxy`, `RunAtLoad`+`KeepAlive` | integrated/omitted in registry-managed set | SCM service `nucleus-caddy`, automatic start | supervised on hosts where managed | `src/scripts/services/caddy-trust.sh`: activation-time CA trust recovery may bootout/bootstrap `httpsProxy` only when sudo trust cannot reach admin (EX_CONFIG/penalty-box recovery path), `# WHY:` present; not steady-state supervision | native=crash recovery, watchdog=liveness/repair, activation helper=one-shot recovery to complete trust |
| `camilladsp` | launchd daemon `local.camilladsp`, `RunAtLoad`+`KeepAlive` | systemd `camilladsp.service`, `Restart=always` | scheduled task `\NucleusCamillaDSP` with internal/managed run loop | supervised | `src/scripts/services/camilladsp-run.sh`: starts camilladsp `--no_config` and waits (single process); no retry/restart loop | native=crash recovery, script=runs DSP process, heartbeat owns config push |
| `camilladsp-heartbeat` | launchd agent `local.camilladsp-heartbeat`, `RunAtLoad`+`KeepAlive` | systemd user `camilladsp-heartbeat.service`, `Restart=always` | scheduled task `\NucleusCamillaDSPHeartbeat` | supervised | `camilladsp-heartbeat.sh` execs Python daemon; daemon/PS loop performs periodic config push and reconnect/backoff (internal loop pattern). No supervisor restart tokens in audited service scripts; process revival owned by native supervisor | native=crash recovery, script=periodic work/backoff, watchdog=liveness/health per policy |
| `camillagui-backend` | launchd daemon `local.camillagui-backend`, `RunAtLoad`+`KeepAlive` | systemd `camillagui-backend.service`, `Restart=always` | scheduled task `\NucleusCamillaGUI` | supervised | no audited restart loop | native=crash recovery |
| `cloud-drive` | per-instance launchd agents `local.cloud-mount.*`, `RunAtLoad`+`KeepAlive`, throttled | per-instance systemd user units `cloud-mount-*`, `Restart=always`, throttled | per-instance scheduled tasks `NucleusCloudMount-*` with wrapper loop + task restart-on-failure defense-in-depth | managed/instanced; mount revival owned by platform manager per mount contract | `rclone-mount.sh` clean+exec (single pass, no in-script retry); `rclone-mount.ps1` internal retry loop (30s) inside task, task `RestartCount`/interval is process-revival backstop; `cloud-drives-setup.sh` prints manual remedy text only (no executed supervisor command) | native/wrapper=mount revival cadence, watchdog not the mount restart owner, setup=provisioning/reporting |
| `discord-music-rpc` | launchd agent, `RunAtLoad`+`KeepAlive` | systemd user, `Restart=always` | scheduled task | supervised | no audited restart loop | native=crash recovery |
| `ds-store-gc` | launchd agent oneshot (`StartCalendarInterval`, no `KeepAlive`) | omitted | omitted | not a persistent daemon | periodic cleanup script run by timer | timer/oneshot |
| `gc-weekly` | omitted in managed service set | omitted | omitted | n/a | periodic job (platform-defined) | timer/oneshot |
| `gui-env` | launchd agent login oneshot (`RunAtLoad`, no `KeepAlive`) | omitted | omitted | not a persistent daemon | activation/login env propagation scripts | oneshot |
| `hermes-agent` | launchd agent, `RunAtLoad`+`KeepAlive` | systemd user, `Restart=always` | SCM/native service | supervised | no audited restart loop | native=crash recovery |
| `icloud-exclusions` | launchd agent periodic oneshot (`StartInterval`, no `KeepAlive`) | omitted | omitted | not a persistent daemon | periodic script | timer/oneshot |
| `jellyfin` | launchd daemon `org.nixos.jellyfin`, `RunAtLoad`+`KeepAlive` | systemd `jellyfin.service`, `Restart=always` | SCM `JellyfinServer` | supervised | no audited restart loop | native=crash recovery |
| `linux-builder` | launchd daemon `org.nixos.linux-builder`, `RunAtLoad`+`KeepAlive` | omitted (native builds) | omitted | supervised on macOS | no audited restart loop; operator/audit helpers outside audited service-script scope may kickstart explicitly (separate concern) | native=crash recovery |
| `litellm` | launchd daemon `local.litellm`, `RunAtLoad`+`KeepAlive` | systemd `litellm.service`, `Restart=always` | SCM `nucleus-litellm` | supervised | `litellm-daemon.sh`: startup waits/polling and execs litellm; no restart loop | native=crash recovery, script=startup readiness |
| `log-gc-system` | launchd daemon periodic oneshot | systemd timer+oneshot service | scheduled task oneshot | not a persistent daemon | oneshot script | timer/oneshot |
| `log-gc-user` | launchd agent periodic oneshot | systemd user timer+oneshot service | scheduled task oneshot | not a persistent daemon | oneshot script | timer/oneshot |
| `nix-index-update` | launchd agent periodic oneshot | systemd user timer+oneshot service | omitted | not a persistent daemon | oneshot script | timer/oneshot |
| `ollama` | launchd daemon `local.ollama`, `RunAtLoad`+`KeepAlive` | systemd `ollama.service`, `Restart=always` | SCM `ollama` | supervised | no audited restart loop | native=crash recovery |
| `rdp` | omitted | omitted | SCM `TermService` | supervised on Windows | no audited restart loop | native/platform service |
| `redis` | launchd daemon `local.redis`, `RunAtLoad`+`KeepAlive` | systemd `nucleus-redis.service`, `Restart=always` | SCM `nucleus-redis` | supervised (watchdog repairs loaded-but-not-running/spawn-failed EX_CONFIG cases and live EX_CONFIG/loops per rules) | no audited restart loop; no per-service restart script | native=crash recovery, watchdog=liveness/repair/accounting |
| `sccache-gc` | launchd agent periodic oneshot | systemd user timer+oneshot service | scheduled task oneshot | not a persistent daemon | oneshot script | timer/oneshot |
| `service-watchdog` | launchd daemon, `RunAtLoad`+`KeepAlive`, 300s internal loop | systemd service, `Restart=always`, 300s internal loop | scheduled task + internal loop (300s) | self (is the watchdog) | `service-watchdog.sh`/`.ps1`: internal tick loop is the watchdog's own work; uses supervisor adapters for start/stop/repair, does not duplicate native crash recovery | native=process revival, watchdog-script=liveness/repair/accounting |
| `service-watchdog-user` | launchd agent, `RunAtLoad`+`KeepAlive`, 300s internal loop | systemd user service, `Restart=always`, 300s internal loop | omitted | self (user-scope watchdog) | same as system watchdog, user scope | native=process revival, watchdog-script=liveness/repair/accounting |
| `spotlight-exclusions` | launchd agent periodic oneshot | omitted | omitted | not a persistent daemon | periodic script | timer/oneshot |
| `ssh-agent` | built-in macOS launchd user agent | systemd user `ssh-agent.service` | SCM `ssh-agent` | supervised/managed per host | no audited restart loop | platform/native service |
| `sshd` | built-in macOS launchd daemon (socket-activated) | systemd `sshd.service` | SCM `sshd` | supervised/managed per host | no audited restart loop | platform/native service |

Audited script set for supervisor restart tokens: src/scripts/services/**, src/platforms/macOS/scripts/**, src/platforms/Windows/modules/**. Current justified findings: `src/scripts/services/caddy-trust.sh` performs activation-time recovery of `org.nixos.httpsProxy` (bootout/bootstrap) when sudo CA trust cannot reach the admin endpoint; `src/scripts/services/cloud-drives-setup.sh` contains only operator-remedy text naming `launchctl bootout` (no executed restart). No per-service restart scripts were added; duplicated watchdog logic was not found in audited service scripts.
