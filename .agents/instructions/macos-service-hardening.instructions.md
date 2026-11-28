---
description: "Use when editing MacBook launchd daemons, Spotlight disable, SIP workarounds, or macOS service recovery."
name: "macOS Service Hardening"
applyTo: "src/hosts/MacBook/*.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, src/hosts/MacBook/defaults.nix, src/hosts/MacBook/services/**, src/platforms/macOS/modules/**/*.nix, src/hosts/MacBook/scripts/macos-set-utm-prefs.sh, src/scripts/lib/macos-launch-services.sh, src/scripts/services/refresh-services-menu.sh, scripts/svc.sh, src/scripts/services/service-watchdog.sh, src/scripts/services/caddy-trust.sh"
---

# macOS service hardening

Spotlight disable has six ordered steps in `src/hosts/MacBook/activation.nix`: `defaults write` false on hotkey IDs 61, 64, 65; `activateSettings -u` as console user; `launchctl disable`; `launchctl bootout` (non-zero when absent is expected, macOS 15+ SIP warning with converged state is a warning); `mdutil -i off /`; remove `/.Spotlight-V100`.

macOS 26+ SIP penalty-boxes a system daemon with non-root `UserName` on unsigned execution (exit 78, `EX_CONFIG`). Wrap `ProgramArguments` as `["/bin/sh", "-c", "exec <nix-path>"]`; exit 126 is expected, never add kickstart logic, and `service-watchdog` recovers every 5 min via `recover_launchctl_service`.

A new defaults domain needs a sorted `resetUserPreferenceDomains` entry for `.GlobalPreferences`/`NSGlobalDomain`; `.policy` domains go through user-terminal activation. Only built-in nix-darwin hook names run (`extraActivation`, `postActivation`), and forked daemons detach stdio. Use `launchd.agents.<name>.serviceConfig`, set `Label`, bundle iCloud files with `builtins.path`, and close the disable gate before `bootout`. Preserve `womp`, `disksleep=sleep`, `lowpowermode`, and `lidwake`; the 80% charge limit uses firmware SMC and stays manual. Wire sops readers to `waitForSopsSecrets`.

Full detail: `src/users/default/agents/skills/nucleus-platform-reference/references/macos-service-hardening.md`.
