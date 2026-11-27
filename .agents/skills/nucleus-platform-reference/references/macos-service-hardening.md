---
description: "Use when editing MacBook launchd daemons, Spotlight disable, SIP workarounds, or macOS service recovery."
name: "macOS Service Hardening"
applyTo: "src/hosts/MacBook/*.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, src/hosts/MacBook/defaults.nix, src/hosts/MacBook/services/**, src/platforms/macOS/modules/**/*.nix, src/hosts/MacBook/scripts/macos-set-utm-prefs.sh, src/scripts/lib/macos-launch-services.sh, src/scripts/services/refresh-services-menu.sh, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS service hardening

## Spotlight

Cmd+Space needs six interdependent steps in `src/hosts/MacBook/activation.nix` `system.activationScripts.postActivation.text`; bindings live in hotkey slots 61, 64, 65 and vary by version and migration.

1. `defaults write enabled=false` on all three IDs; migrations preserve old entries.
2. `activateSettings -u` as console user immediately after, or the change waits for login.
3. `launchctl disable` blocks auto-start so updates cannot restore it.
4. `launchctl bootout` kills the running job; non-zero when already absent is expected. macOS 15+ may return `Operation not permitted while SIP is engaged` with state converged: warn, do not fail.
5. `mdutil -i off /` disables filesystem indexing.
6. Remove `/.Spotlight-V100`; indexing is off, so nothing rebuilds it.

Steps 3 to 5 need root, unavailable to user context through `sudo`.

## SIP daemon wrapper

macOS 26+ SIP blocks a system daemon with non-root `UserName` from running an unsigned binary at boot. Exit 78 (`EX_CONFIG`) is non-retryable and penalty-boxes the job; `launchd.agents` is unaffected. Symptoms: `last exit code = 78: EX_CONFIG` in `launchctl print system/<label>`, no output, bootout plus bootstrap works after login.

Wrap every `launchd.daemons` entry with non-root `UserName` as `ProgramArguments = [ "/bin/sh" "-c" "exec <nix-path>" ];`. `/bin/sh` is Apple-signed and `exec` preserves PID. Exit 126 is expected after `exec`: no penalty box, `KeepAlive` restarts, `StartInterval` retries next tick. Never add kickstart logic. `service-watchdog` already recovers the penalty box every 5 min via `recover_launchctl_service` (`bootout` then `bootstrap` from `/Library/LaunchDaemons/<label>.plist`).

## Defaults and activation

A new defaults domain in `defaults.nix` or `src/platforms/macOS/modules/default.nix` needs an alphabetically sorted `resetUserPreferenceDomains` entry in `src/platforms/macOS/modules/preference-gc.nix` in the same change, with `.GlobalPreferences` counted for `NSGlobalDomain`. That list drives `nucleus-gc preferences`, a domain wipe gated on `nix --verify`, never a `home.activation.*` or Darwin apply step. `.policy`-suffixed and daemon-owned domains such as `com.apple.PassKit.policy` revert during `darwin-rebuild switch`; provision them from user-terminal activation scripts, not `CustomUserPreferences` (`macos-configure-passwords-defaults.sh`).

nix-darwin calls only `preActivation`, `extraActivation`, and `postActivation`; custom names are evaluated but not called. Extension points: `extraActivation` after `createRun` before `openssh`, `postActivation` after `homebrew`, Home Manager launchd `entryAfter [ "setupLaunchAgents" ]`. NixOS supports custom names. Forked daemons detach stdio (`</dev/null >/dev/null 2>&1`) or apply hangs.

## launchd management

Use `launchd.agents.<name>.serviceConfig`, not `.enable` or `.config`; `types.path` rejects tilde paths. Set `Label` on daemons. Root cannot read iCloud Drive, so bundle files with `builtins.path`; root without `UserName` has no `HOME`, so use `${HOME:-}` under `set -u`.

The disabled flag is a load-time gate: `launchctl disable` records an override while a running `KeepAlive` job keeps running, and `enable` starts nothing (man launchctl, LEGACY SUBCOMMANDS: `load`/`unload` map to `bootstrap`/`bootout` and `enable`/`disable` separately; `-w` overrides the Disabled key). `nucleus-svc disable` closes the gate before `bootout` to avoid respawn; `enable` only clears it. A disabled job cannot be bootstrapped, so `setupLaunchAgents` reports it next apply by design. `nucleus-svc stop` warns for `macos-launchctl` entries without `onDemand` (explicit start); `svc.ps1` owns scheduled tasks; systemd entries carry none.

## Services menu, power, secrets

`~/Library/Services` is read by per-user `pbs`, not LaunchServices. `home.activation.macosFlushServicesCache` (`src/scripts/services/refresh-services-menu.sh`) runs as console user (`launchctl asuser <uid> sudo -H -u <user>`), never root. Killing pbs re-reads caches only; rescan needs `pbs -update` (bare `pbs` exits 1), `pbs -flush` is escalation, `pbs -read_bundle <bundle>` proves parsing. `FinderOrdering` is advisory and label-keyed; stranded entries are inert, so clean them one-off.

`src/hosts/MacBook/activation.nix` is SSOT for `pmset`. Preserve `womp` on `-c` and `-b`, `disksleep` equal to `sleep`, per-source `lowpowermode` before timer values, global `lidwake` (`-a`). Do not write `Sleep On Power Button` or `SleepServices` on Apple Silicon or macOS 15+. The 80% limit uses `src/hosts/MacBook/scripts/macos-charge-limit.sh` and `battery maintain 80` through firmware SMC; macOS Charge Limit has no `pmset` key, profile, or setter, so it stays manual in `MANUAL.md`. Do not reintroduce Shortcuts; `tests/scripts/macos-charge-limit-tests.sh` asserts that.

sops-nix installs secrets via a LaunchAgent, so `entryAfter = [ "sops-nix" ]` does not wait for files. Wire `git-identity`, `gpg-import`, `ssh-key-adopt`, and other readers to `waitForSopsSecrets`.
