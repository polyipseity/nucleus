---
description: "Use when editing MacBook launchd daemons, Spotlight disable, SIP workarounds, or macOS service recovery scripts."
name: "macOS Service Hardening"
applyTo: "src/hosts/MacBook/*.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, src/hosts/MacBook/defaults.nix, src/hosts/MacBook/services/**, src/platforms/macOS/modules/**/*.nix, src/hosts/MacBook/scripts/macos-set-utm-prefs.sh, src/scripts/lib/macos-launch-services.sh, src/scripts/services/refresh-services-menu.sh, tests/integration/activation-deps-tests.nix, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS service hardening

## Spotlight disable

Spotlight (cmd+space) cannot be disabled by a single shortcut — macOS stores bindings across symbolic-hotkey slots 61, 64, 65, varying by OS version and migration history. Six interdependent stages are required; removing any one causes partial re-enablement. Implementation: `src/hosts/MacBook/activation.nix`.

### Stage 1: Disable hotkey IDs (61, 64, 65)

Write `enabled=false` to each via `defaults write`. macOS uses different slots across versions; profile migrations preserve old entries — disabling only one leaves Cmd+Space active.

### Stage 2: Invoke activateSettings -u

Must run as the console user (not root) immediately after hotkey writes. Without this, the disable only takes effect at next login.

### Stage 3: launchctl disable

Removes Spotlight from the auto-start registry. System updates can re-enable it; `launchctl disable` prevents reboot-based restoration.

### Stage 4: launchctl bootout

Terminates the running service (`launchctl disable` only prevents re-launch). Non-zero exit if already absent is expected — log as warning. macOS 15+: bootout may return `Operation not permitted while SIP is engaged` even when state has converged — treat as classified warning, not hard error.

### Stage 5: mdutil -i off /

Disables indexing at the filesystem layer — stays off even if an admin or update re-enables the launchd service. Requires root; must run in `system.activationScripts`, not `home.activation`.

### Stage 6: Remove `/.Spotlight-V100`

Deletes the index cache. Without it, Spotlight must rebuild from scratch if re-enabled — combined with `mdutil -i off`, no indexed data is available.

All six stages run in `system.activationScripts.postActivation.text` (root via `darwin-rebuild switch`). Three require root unavailable via `sudo` in user context: `mdutil`, `bootout`, `disable`.

After applying, verify: hotkey IDs 61/64/65 disabled, `mdutil -s /` reports no indexing, `launchctl list | grep Spotlight` empty, `/.Spotlight-V100` absent, cmd+space does not open Spotlight.

## SIP / launchd daemon restriction

macOS 26+ SIP blocks **system launchd daemons** with non-root `UserName` from executing unsigned binaries at boot. Exit code 78 (`EX_CONFIG`) — non-retryable, launchd enters penalty box. Does not affect `launchd.agents`.

Symptoms: `launchctl print system/<label>` shows `last exit code = 78: EX_CONFIG` and penalty box; zero stdout/stderr; `bootout + bootstrap` works after login.

### Canonical workaround

Wrap `ProgramArguments` in `["/bin/sh", "-c", "exec <nix-path>"]`. `/bin/sh` is Apple-signed and passes SIP; `exec` replaces the shell with the Nix binary, preserving PID and process semantics.

```nix
ProgramArguments = [
  "/bin/sh"
  "-c"
  "exec ${pkgs.ollama}/bin/ollama serve"
];
```

Apply to every `launchd.daemons` entry with a non-root `UserName`. The restriction applies to any unsigned Nix store file.

### Recovery from penalty box

1. `sudo launchctl bootout system/<label>` — clears exit memory
2. `sudo launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` — reloads

The `service-watchdog` (every 5 min) does this automatically via `recover_launchctl_service`.

### Exit 126 vs exit 78

- **Exit 78 (EX_CONFIG)** — non-retryable penalty box. Requires `bootout + bootstrap`.
- **Exit 126** — expected from the `/bin/sh -c exec` wrapper (shell exits after exec). Not an error; no penalty box. `KeepAlive` daemons restart immediately; `StartInterval` retries on next tick. Do not add kickstart logic.

## macOS defaults domain synchronization

When adding a new defaults domain in `defaults.nix` or `src/platforms/macOS/modules/default.nix`, update `resetUserPreferenceDomains` in `src/platforms/macOS/modules/preference-gc.nix` simultaneously (alphabetically sorted). If `NSGlobalDomain`, account for the `.GlobalPreferences` alias.

`resetUserPreferenceDomains` drives `nucleus-gc preferences` — domain-level destructive GC (wipes entire plist), gated on `nix --verify`. Never wire into `home.activation.*` or Darwin apply path.

`.policy`-suffixed / daemon-owned domains (e.g. `com.apple.PassKit.policy`) revert writes during `darwin-rebuild switch`. Provision from user-terminal activation scripts, not `CustomUserPreferences` — see `macos-configure-passwords-defaults.sh`.

## nix-darwin activation scripts

nix-darwin only invokes built-in hook names. Custom `system.activationScripts.<name>.text` entries are evaluated but not invoked unless the name matches.

Extension points: `extraActivation` (after `createRun`, before `openssh`), `postActivation` (after `homebrew`), Home Manager launchd (`entryAfter [ "setupLaunchAgents" ]`). Use `lib.mkBefore` for fragments before HM defaults (add `lib` to module args). NixOS supports custom names.

Background-process safety: forked daemons must detach stdio (`</dev/null >/dev/null 2>&1`) or apply hangs on pipe FDs.

## macOS launchd service management

Use `launchd.agents.<name>.serviceConfig` (not `.enable`/`.config`). `types.path` rejects tilde paths — use absolute paths. HM launchd module unchanged (`enable` + `config`).

Set `Label` explicitly for `launchd.daemons` (e.g. `local.camilladsp`). Root processes cannot read iCloud Drive — bundle files into the nix store via `builtins.path`. Root without `UserName` has `HOME` unset — use `${HOME:-}` with `set -u`.

## Services menu discovery (NSServices)

`~/Library/Services` is discovered by `pbs`, not by LaunchServices, and per-user: pbs keeps its own caches, so a refresh must run in the console user's session (`launchctl asuser <uid> sudo -H -u <user>`), never as root. Killing pbs only re-reads those caches — it does not rescan — and pbs's change detection (FSEvents) misses a bundle replaced or renamed in place, so a renamed workflow keeps its stale registration and a newly provisioned one stays invisible until the next login.

`home.activation.macos-flush-services-cache` runs `src/scripts/services/refresh-services-menu.sh` after the Automator-workflow and app-bundle deploy steps: it flushes the daemon caches, then forces a rescan with `pbs -update`, which rewrites both the userdef cache and the services pasteboard the menus are built from. A bare `pbs` is not an alternative — this build prints its usage and exits 1. `pbs -flush` (erase the cache, rescan on next need) is the documented escalation when `-update` proves insufficient, and `pbs -read_bundle <bundle>` prints one bundle's declaration without touching the cache — use it to prove a bundle parses before blaming the cache. `FinderOrdering` is Finder-owned advisory ordering keyed by the service label, so a label rename strands an entry under the old label; stranded entries are inert (Finder ignores labels that no longer exist) and are cleaned up one-off, never pruned from a script.

## macOS pmset power policy

`src/hosts/MacBook/activation.nix` (`postActivation`) is the SSOT for managed `pmset` writes. Preserve: `womp` on both `-c` and `-b`; `disksleep` equal to `sleep`; per-source `lowpowermode` before timer values; global `lidwake` (`-a`). Do not write `Sleep On Power Button` or `SleepServices` via `pmset` on Apple Silicon/macOS 15+.

The 80 % charge limit is separate from `pmset` and lives in `src/hosts/MacBook/scripts/macos-charge-limit.sh`, which converges the `battery` CLI (`battery maintain 80`) and nothing else — a firmware-level SMC charging gate plus its headless `com.battery.app` LaunchAgent. macOS's own Charge Limit (26.4+) is deliberately left out: it has no `pmset` key, no configuration-profile payload, and no supported setter (Apple exposes it to the Settings UI and to a Shortcuts action whose workflow cannot be authored from the command line, and its value sits in Apple's private `powerd` archive, which is not ours to write). It stays a one-time manual setting (`src/hosts/MacBook/MANUAL.md`) and is the backstop for a `battery` helper regression, which has happened on macOS 26.x — the firmware gate is the only automatic cap, so do not reintroduce the shortcut path; `tests/scripts/macos-charge-limit-tests.sh` asserts it stays out.

## sops-nix macOS LaunchAgent async behaviour

sops-nix on macOS installs secrets via LaunchAgent — `entryAfter = [ "sops-nix" ]` does not gate on files landing on disk. Wire `git-identity`, `gpg-import`, `ssh-key-adopt`, and other sops readers to `waitForSopsSecrets` (polling barrier) instead.
