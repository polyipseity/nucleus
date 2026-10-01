---
description: "Use when editing MacBook launchd daemons, Spotlight disable, SIP workarounds, or macOS service recovery scripts."
name: "macOS Service Hardening"
applyTo: "src/hosts/MacBook/*.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, src/hosts/MacBook/defaults.nix, src/hosts/MacBook/services/**, src/platforms/macOS/modules/**/*.nix, src/hosts/MacBook/scripts/macos-set-utm-prefs.sh, src/scripts/lib/macos-launch-services.sh, src/scripts/services/refresh-services-menu.sh, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS service hardening

## Spotlight disable

Spotlight (cmd+space) cannot be disabled by a single shortcut: macOS stores bindings across symbolic-hotkey slots 61, 64, 65, varying by OS version and migration history, and the stages below are interdependent. Implementation: `src/hosts/MacBook/activation.nix`.

1. `defaults write` `enabled=false` to hotkey IDs 61, 64, 65. Profile migrations preserve old entries, so disabling only one leaves Cmd+Space active.
2. `activateSettings -u` as the console user, right after the writes. Without it the disable only takes effect at next login.
3. `launchctl disable` removes it from the auto-start registry, so a system update cannot restore it.
4. `launchctl bootout` kills the running service; `disable` alone only blocks re-launch. A non-zero exit when already absent is expected. macOS 15+ may return `Operation not permitted while SIP is engaged` with the state converged: log a warning, do not fail.
5. `mdutil -i off /` disables indexing at the filesystem layer, so an admin or update re-enabling the launchd service does not bring it back.
6. Remove `/.Spotlight-V100`; with indexing off nothing is left to rebuild from.

All six run in `system.activationScripts.postActivation.text`. `mdutil`, `bootout`, and `disable` need root, which user context cannot get through `sudo`.

## SIP and launchd daemon restriction

macOS 26+ SIP stops a system launchd daemon with non-root `UserName` from executing an unsigned binary at boot. Exit 78 (`EX_CONFIG`) is non-retryable and puts the job in the penalty box; `launchd.agents` is unaffected. Symptoms: `launchctl print system/<label>` shows `last exit code = 78: EX_CONFIG`, zero stdout/stderr, and `bootout + bootstrap` works after login.

Wrap `ProgramArguments` in `["/bin/sh", "-c", "exec <nix-path>"]` for every `launchd.daemons` entry with a non-root `UserName`: `/bin/sh` is Apple-signed and passes SIP, and `exec` preserves the PID and process semantics.

```nix
ProgramArguments = [
  "/bin/sh"
  "-c"
  "exec ${pkgs.ollama}/bin/ollama serve"
];
```

Exit 126 is expected from that wrapper (the shell exits after `exec`), not an error: no penalty box, `KeepAlive` daemons restart immediately, `StartInterval` retries on the next tick. Never add kickstart logic. Recovery from the penalty box is `launchctl bootout system/<label>` then `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist`, which `service-watchdog` already does every 5 min via `recover_launchctl_service`.

## macOS defaults domain synchronization

A new defaults domain in `defaults.nix` or `src/platforms/macOS/modules/default.nix` needs a matching alphabetically sorted entry in `resetUserPreferenceDomains` (`src/platforms/macOS/modules/preference-gc.nix`) in the same change; for `NSGlobalDomain`, account for the `.GlobalPreferences` alias. `resetUserPreferenceDomains` drives `nucleus-gc preferences`, a domain-level wipe gated on `nix --verify`, so it never belongs in `home.activation.*` or the Darwin apply path.

`.policy`-suffixed and daemon-owned domains such as `com.apple.PassKit.policy` revert writes during `darwin-rebuild switch`; provision them from user-terminal activation scripts, not `CustomUserPreferences` (see `macos-configure-passwords-defaults.sh`).

## nix-darwin activation scripts

nix-darwin invokes only built-in hook names; a custom `system.activationScripts.<name>.text` is evaluated but never called. Extension points: `extraActivation` (after `createRun`, before `openssh`), `postActivation` (after `homebrew`), Home Manager launchd (`entryAfter [ "setupLaunchAgents" ]`). NixOS supports custom names. Forked daemons must detach stdio (`</dev/null >/dev/null 2>&1`) or apply hangs on the pipe.

## launchd service management

Use `launchd.agents.<name>.serviceConfig`, not `.enable`/`.config`; `types.path` rejects tilde paths. Set `Label` explicitly on `launchd.daemons`. Root cannot read iCloud Drive, so bundle files into the store with `builtins.path`; root without `UserName` has no `HOME`, so use `${HOME:-}` under `set -u`.

## Services menu discovery (NSServices)

`~/Library/Services` is read by `pbs`, not LaunchServices, and pbs is per-user with its own caches, so `home.activation.macos-flush-services-cache` (`src/scripts/services/refresh-services-menu.sh`) must run as the console user (`launchctl asuser <uid> sudo -H -u <user>`), never as root. Killing pbs only re-reads its caches, it does not rescan, and its FSEvents change detection misses a bundle replaced in place, so a rescan needs `pbs -update`; a bare `pbs` prints usage and exits 1. `pbs -flush` is the escalation when `-update` is not enough, and `pbs -read_bundle <bundle>` proves a bundle parses without touching the cache. `FinderOrdering` is Finder-owned advisory ordering keyed by the service label: a renamed label strands an entry under the old one, and stranded entries are inert, so clean them one-off instead of pruning from the script.

## macOS pmset power policy

`src/hosts/MacBook/activation.nix` (`postActivation`) is the SSOT for managed `pmset` writes. Preserve `womp` on both `-c` and `-b`, `disksleep` equal to `sleep`, per-source `lowpowermode` before the timer values, and global `lidwake` (`-a`). Do not write `Sleep On Power Button` or `SleepServices` through `pmset` on Apple Silicon or macOS 15+.

The 80 % charge limit is separate: `src/hosts/MacBook/scripts/macos-charge-limit.sh` converges `battery maintain 80` through the firmware SMC gate, and macOS's own Charge Limit has no `pmset` key, profile payload, or command-line setter, so it stays a one-time manual setting in `src/hosts/MacBook/MANUAL.md`. The firmware gate is the only automatic cap; do not reintroduce the Shortcuts path, and `tests/scripts/macos-charge-limit-tests.sh` asserts it stays out.

## sops-nix macOS LaunchAgent async behaviour

sops-nix installs secrets through a LaunchAgent on macOS, so `entryAfter = [ "sops-nix" ]` does not gate on the files landing. Wire `git-identity`, `gpg-import`, `ssh-key-adopt`, and the other sops readers to `waitForSopsSecrets` instead.
