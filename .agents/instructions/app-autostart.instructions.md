---
description: "Use when adding, editing, or reviewing GUI/user app auto-start or menu-bar/tray-icon entries in apps.json or the convergence tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, Sync-MenuBar.ps1). Enforces the never-app-owned-startup policy, platform-prefixed kinds, single uniform mechanism per platform, and the menu-bar icon registry."
name: "App Auto-Start & Menu-Bar Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, src/platforms/Windows/modules/user/Sync-MenuBar.ps1, src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh, src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
---

# App auto-start registry

One mechanism per app per host, ours rather than the app's: disable native auto-start, install a nucleus-owned mechanism (LaunchAgent, XDG `.desktop`, Run key or Startup `.lnk`), and neutralize app-owned agents in both plist forms. Embedded LoginItems cannot be unregistered on macOS 13+, so disable them in app settings and mark the app not fully convergent. `services.json` is for daemons; `apps.json` for foreground GUI, including menu-bar apps.

Registry kinds: `macos-launchagent`, `macos-system-extension`, `manual`, `nixos-xdg-desktop`, `windows-run-key`, `windows-startup-folder`. Platform-owned kinds carry platform prefixes; `autostartEnabled` is required for launched kinds and absent for `manual`. Converge with `autostart.sh`/`.ps1` and `Sync-AppAutostart.ps1`; a new app must pass `verify`.

`statusIcon` in `apps.json` is the single source for menu-bar icons, converged by `menu-bar.sh`/`.ps1` and `Sync-MenuBar.ps1`. MacBook hides icons by default except Amphetamine, Stats, Mounty, and OrbStack; system items have their own defaults and spacing uses 0 with fallback 4. ByHost plists go through `macos-console-user.sh`.

Full tables and commands: `src/users/default/agents/skills/nucleus-platform-reference/references/app-autostart.md`.
