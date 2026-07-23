---
description: "Use when creating or editing macOS launchd daemons with non-root UserName, or working with service recovery scripts. Covers macOS 26+ SIP restriction blocking unsigned Nix store binaries at boot, the /bin/sh wrapper workaround, and penalty-box recovery."
name: "macOS SIP / launchd Daemon Restriction"
applyTo: "src/hosts/MacBook/*.nix, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS SIP / launchd daemon restriction

## Problem

macOS 26+ (Sequoia) SIP blocks **system launchd daemons** that have a non-root `UserName` from executing unsigned binaries at boot during `RunAtLoad`. The daemon exits immediately with exit code 78 (`EX_CONFIG`), which is a non-retryable error — launchd marks it with a `penalty box` and never retries. The service becomes permanently stuck until manually recovered.

This restriction only affects the **system domain** (`launchd.daemons`). User domain agents (`launchd.agents`) are not affected because they start after login when the user session is established.

Common symptoms:

- `launchctl print system/<label>` shows `last exit code = 78: EX_CONFIG` and `penalty box` in properties
- Zero stdout/stderr output (the binary never starts)
- `bootout + bootstrap` (via `nucleus-svc restart`) works after login

## Canonical workaround

Wrap the `ProgramArguments` value in `["/bin/sh", "-c", "exec <nix-path>"]`.

`/bin/sh` is Apple-signed and passes SIP's gate. The `exec` replaces the shell process with the intended Nix store binary, preserving PID and process semantics.

```nix
ProgramArguments = [
  "/bin/sh"
  "-c"
  "exec ${pkgs.ollama}/bin/ollama serve"
];
```

Apply this to **every** `launchd.daemons` entry with a non-root `UserName`, regardless of whether the program is a compiled binary or a `writeShellScript`. The restriction applies to any unsigned file in the Nix store.

## Reference

`camillagui-backend.nix` was the reference — it used the `/bin/sh` wrapper and worked at boot while direct-binary daemons failed. Services with `RunAtLoad = false` + `StartInterval` also survived the boot window by delaying past the strict phase, but the `/bin/sh` wrapper is the correct permanent fix.

## Recovery from penalty box

When a daemon is stuck in penalty box (EX_CONFIG):

1. `sudo launchctl bootout system/<label>` — clears exit memory
2. `sudo launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` — reloads

The `service-watchdog` (every 5 min) does this automatically via `recover_launchctl_service` for all tracked services.

## Exit 126 vs exit 78

- **Exit 78 (EX_CONFIG)** — non-retryable: launchd sets `penalty box` and never retries. Requires manual or watchdog recovery via `bootout + bootstrap`.
- **Exit 126** — expected steady state from the `/bin/sh -c exec` wrapper, not an error. The shell performing `exec` exits with 126 after the replacement binary takes over under PPID=1 (launchd). Logging, restart, and resource usage work normally. Launchd does NOT set `penalty box` for exit 126 — `KeepAlive` daemons restart immediately; `StartInterval` services retry on the next interval. Do not add kickstart logic to "fix" this.
