---
description: "Use when editing MacBook launchd daemons, Spotlight disable, SIP workarounds, or macOS service recovery scripts."
name: "macOS Service Hardening"
applyTo: "src/hosts/MacBook/*.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, src/hosts/MacBook/defaults.nix, src/platforms/macOS/modules/**/*.nix, src/hosts/MacBook/scripts/macos-set-utm-prefs.sh, tests/integration/activation-deps-tests.nix, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS service hardening

## Spotlight disable

Spotlight (cmd+space) cannot be fully disabled by setting a single keyboard shortcut. macOS stores the binding across multiple symbolic-hotkey slots (61, 64, 65) depending on OS version, migration history, and hardware platform.

The working solution comprises six interdependent stages, each handling a different layer of Spotlight control. Removing any single stage will cause Spotlight to re-enable or partially persist. Canonical implementation: `src/hosts/MacBook/activation.nix`.

### Stage 1: Disable all three hotkey IDs (61, 64, 65)

Loop over symbolic-hotkey IDs 61, 64, 65 and write `enabled=false` to each via `defaults
write`. macOS uses different ID slots across versions (Mojave→Sequoia), and profile
migrations preserve old entries — disabling only one ID still leaves Cmd+Space active.

### Stage 2: Invoke activateSettings -u immediately

Call `activateSettings -u` as the console user immediately after the hotkey writes.
Without this, the disable applies only to the next login session — Cmd+Space still works
until logout. Must run as the console user (not root) because it operates on the user's
session context.

### Stage 3: launchctl disable — prevent re-launch on reboot

Disable the `com.apple.Spotlight` launchd service. System updates can re-enable it;
`launchctl disable` removes it from the auto-start registry, preventing reboot-based
restoration.

### Stage 4: launchctl bootout — stop running instance immediately

Boot out the running `com.apple.Spotlight` service. `launchctl disable` prevents re-launch
but does not stop an already-running process, so `bootout` terminates it now.

`bootout` may exit non-zero if the service is already absent (e.g., a previous activation
already stopped it). This is expected; log it as a warning, not an error.

SIP nuance (macOS 15+): `launchctl bootout gui/<uid>/com.apple.Spotlight` can return
`Operation not permitted while System Integrity Protection is engaged` even when
`launchctl disable` and `mdutil -i off /` have already converged the effective state. Treat
this as an expected classified warning (not a hard error), and avoid printing raw
unclassified `launchctl` output directly in activation logs.

### Stage 5: mdutil -i off / — disable Spotlight indexing globally

Disable Spotlight indexing at the filesystem level for the root volume. `mdutil -i off /` is
enforced at the kernel/storage layer, so indexing stays off even if an admin or macOS update
re-enables the launchd service. Requires root privileges — must run in
`system.activationScripts`, not `home.activation`.

### Stage 6: Remove cache directory `/.Spotlight-V100`

Delete the existing Spotlight index cache at `/.Spotlight-V100`. Without a pre-built cache,
Spotlight must rebuild from scratch if re-enabled. Combined with `mdutil -i off`, this
ensures no indexed data is available.

The entire strategy runs in `system.activationScripts.postActivation.text` (as root via
`darwin-rebuild switch`), not `home.activation`. Three operations require root privilege
unavailable with `sudo` in user context: (1) `mdutil -i off /`, (2) `launchctl bootout`,
(3) `launchctl disable`.

After applying, verify hotkey IDs 61/64/65 show disabled, `mdutil -s /` reports no indexing, `launchctl list | grep Spotlight` is empty, `/.Spotlight-V100` is absent, and cmd+space does not open Spotlight in the active GUI session.

## SIP / launchd daemon restriction

macOS 26+ (Sequoia) SIP blocks **system launchd daemons** that have a non-root `UserName` from executing unsigned binaries at boot during `RunAtLoad`. The daemon exits immediately with exit code 78 (`EX_CONFIG`), which is non-retryable — launchd marks it with a `penalty box` and never retries.

This restriction only affects the **system domain** (`launchd.daemons`). User domain agents (`launchd.agents`) are not affected.

Common symptoms:

- `launchctl print system/<label>` shows `last exit code = 78: EX_CONFIG` and `penalty box` in properties
- Zero stdout/stderr output (the binary never starts)
- `bootout + bootstrap` (via `nucleus-svc restart`) works after login

### Canonical workaround

Wrap the `ProgramArguments` value in `["/bin/sh", "-c", "exec <nix-path>"]`.

`/bin/sh` is Apple-signed and passes SIP's gate. The `exec` replaces the shell process with the intended Nix store binary, preserving PID and process semantics.

```nix
ProgramArguments = [
  "/bin/sh"
  "-c"
  "exec ${pkgs.ollama}/bin/ollama serve"
];
```

Apply this to **every** `launchd.daemons` entry with a non-root `UserName`. The restriction applies to any unsigned file in the Nix store.

`camillagui-backend.nix` was the reference — it used the `/bin/sh` wrapper and worked at boot while direct-binary daemons failed. The `/bin/sh` wrapper is the correct permanent fix.

### Recovery from penalty box

When a daemon is stuck in penalty box (EX_CONFIG):

1. `sudo launchctl bootout system/<label>` — clears exit memory
2. `sudo launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` — reloads

The `service-watchdog` (every 5 min) does this automatically via `recover_launchctl_service` for all tracked services.

### Exit 126 vs exit 78

- **Exit 78 (EX_CONFIG)** — non-retryable: launchd sets `penalty box` and never retries. Requires manual or watchdog recovery via `bootout + bootstrap`.
- **Exit 126** — expected steady state from the `/bin/sh -c exec` wrapper, not an error. The shell performing `exec` exits with 126 after the replacement binary takes over under PPID=1 (launchd). Logging, restart, and resource usage work normally. Launchd does NOT set `penalty box` for exit 126 — `KeepAlive` daemons restart immediately; `StartInterval` services retry on the next interval. Do not add kickstart logic to "fix" this.

## macOS defaults domain synchronization

- When adding a new managed macOS defaults domain in either `src/hosts/MacBook/defaults.nix` or `src/platforms/macOS/modules/default.nix`, update `resetUserPreferenceDomains` in `src/platforms/macOS/modules/preference-gc.nix` simultaneously.
- Keep `resetUserPreferenceDomains` alphabetically sorted.
- If the managed domain is `NSGlobalDomain`, also account for the on-disk `.GlobalPreferences` alias.
- `resetUserPreferenceDomains` drives the manual drift-reset command `nucleus-gc preferences` (backed by `macos-purge-preferences.sh`). The GC is domain-level destructive — it wipes the whole plist including unmanaged keys — and is gated on `nix --verify`, so it must stay manual and never be wired into `home.activation.*` or the Darwin apply path.
- `.policy`-suffixed / daemon-owned preference domains (e.g. `com.apple.PassKit.policy`) revert writes made during `darwin-rebuild switch` and must be provisioned from a user-terminal activation script rather than `CustomUserPreferences`; see `macos-configure-passwords-defaults.sh`.

## nix-darwin activation scripts

nix-darwin only executes activation hooks from a fixed internal list. Custom `system.activationScripts.<custom-name>.text` entries are evaluated but not invoked unless `<custom-name>` is a built-in hook name.

Use these extension points only:

- `extraActivation`: after `createRun`, before `openssh`.
- `postActivation`: after `homebrew`.
- Home Manager launchd: custom steps that verify agents must use `entryAfter [ "setupLaunchAgents" ]`.

Use `lib.mkBefore` for fragments that must run before HM defaults; add `lib` to module arguments when using `lib.mkBefore`. On NixOS, custom `system.activationScripts.<name>.text` entries are supported.

Background-process safety: activation commands that fork persistent daemons must fully detach stdio (`</dev/null >/dev/null 2>&1`), or apply can hang on inherited pipe FDs.

## macOS launchd service management

### nix-darwin launchd API (rev a1fa429+)

- Replace `launchd.agents.<name>.enable` / `.config` with `launchd.agents.<name>.serviceConfig`.
- `types.path` rejects tilde paths — use absolute paths for log files.
- Home Manager's launchd module is unchanged (`enable` + `config`).

### Label naming

Always set `Label` explicitly in `serviceConfig` for `launchd.daemons` entries (e.g. `local.camilladsp`). Do not rely on nix-darwin auto-generated labels.

### Root processes and iCloud Drive

Root launchd processes cannot read iCloud Drive paths. Bundle files into the nix store with `builtins.path` instead of runtime filesystem reads.

### HOME in root launchd processes

When running as root without `UserName`, `HOME` is unset — use `${HOME:-}` in scripts with `set -u`.

## macOS pmset power policy

`src/hosts/MacBook/activation.nix` (`postActivation`) is the SSOT for managed `pmset` writes. Preserve: `womp` on both `-c` and `-b`; `disksleep` equal to `sleep`; per-source `lowpowermode` before timer values; global `lidwake` (`-a`). Do not write `Sleep On Power Button` or `SleepServices` via `pmset` on Apple Silicon/macOS 15+.

## sops-nix macOS LaunchAgent async behaviour

sops-nix on macOS installs secrets via LaunchAgent — `entryAfter = [ "sops-nix" ]` does not gate on files landing on disk. Wire `git-identity`, `gpg-import`, `ssh-key-adopt`, and other sops readers to `waitForSopsSecrets` (polling barrier) instead.
