---
description: "Use when adding, editing, or reviewing GUI/user app auto-start or menu-bar/tray-icon entries in apps.json or the convergence tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, Sync-MenuBar.ps1). Enforces the never-app-owned-startup policy, platform-prefixed kinds, single uniform mechanism per platform, and the menu-bar icon registry."
name: "App Auto-Start & Menu-Bar Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, src/platforms/Windows/modules/user/Sync-MenuBar.ps1, src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh, src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
---

# App auto-start registry

## Policy

One mechanism per app per host, and it is ours rather than the app's:

1. Disable the native auto-start: macOS "Open at Login", the Windows Run key, the Linux XDG `.desktop`.
2. Install ours uniformly: a nucleus-owned LaunchAgent plist on macOS (`~/Library/LaunchAgents/local.<bundle-id>.plist`), an XDG `.desktop` on NixOS, a Run-key or Startup-folder `.lnk` on Windows. TCC: the script runner may need Accessibility on first run.
3. Neutralise the app's own agent. Convergence removes the app-owned plist in both forms (`ProgramArguments` array and scalar `Program`); recognising only one leaves the app starting twice. Embedded Service-Management helpers (`Contents/Library/LoginItems`) cannot be unregistered by a script on macOS 13+, so disable them in the app's own settings and record the app as not fully convergent.

`services.json` is for background daemons, `apps.json` for foreground GUI, including menu-bar apps such as `battery`. `omitted` only when no build exists for the platform, and the entry states inapplicability rather than a substitute.

## Registry

`src/modules/apps.json`, validated by `apps.schema.json` and `registry-common.schema.json`. Per host, `kind` is `macos-launchagent`, `macos-system-extension`, `manual`, `nixos-xdg-desktop`, `windows-run-key`, or `windows-startup-folder`, and `autostartEnabled` is required for every launched kind and omitted for `manual`. Platform-owned kinds carry a platform prefix, so a kind that does not belong to its host's platform fails validation. Disabling native auto-start follows from `kind` and is not declared per entry. `macos-system-extension` means only macOS can grant the approval; `manual` means no script can converge the app; both report the entry's `approvalInstructions` and change nothing.

Converge with `src/scripts/autostart.sh`/`.ps1` (`list`, `status`, `enable`, `disable`, `apply`, `verify`) and `Sync-AppAutostart.ps1` on Windows.

Adding an app: block it in `apps.json` with host keys or `omitted` plus `justification`, set `autostartEnabled` unless the kind is `manual`, pick `kind` per host, run `autostart.sh apply`, require `verify` to pass, and drop any ad-hoc script in the same change.

## Menu-bar and tray icons

`apps.json` `statusIcon` is the single source of truth, converged by `menu-bar.sh`/`.ps1` (`list`, `status`, `show`, `hide`, `apply`, `verify`) and `Sync-MenuBar.ps1`. `macos-plist` restarts the daemon via `pgrep`/`pkill` bundleId. A block with auto-start enabled disables the native one; an icon block only sets state and never disables anything. `justification` is required for allow-listed apps and omitted blocks.

## Menu-bar icon policy

MacBook hides every icon by default, except the allow-list: Amphetamine (LSUIElement), Stats (replaces battery), Mounty (NTFS, menu-bar-only), OrbStack (VM/container).

| Class | Mechanism | Examples |
| --- | --- | --- |
| a | Declarative `apps.json` `statusIcon` | Raycast, BetterDisplay, AltTab, Rectangle, LinearMouse, LuLu |
| b | ⌘-drag (per-session) | MiddleClick |
| c | Primary UI | Equaliser |
| d | No option | Parsec, Telegram, WhatsApp, Steam |
| f | macOS 26 `NSStatusItem` gate | Amphetamine, Stats, Mounty, OrbStack |

System items: Siri (`StatusMenuVisible`), Spotlight (`MenuItemHidden`, ByHost), Input Menu (`TextInputMenu.visible`), battery (`Battery = 12`, ByHost).

Spacing `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` take 0 minimum, falling back to 4 on overlap. The macOS 26 gate is `defaults write com.apple.controlcenter "NSStatusItem Visible <BundleID>"` via `menu-bar.sh`, and a no-op before Tahoe. No hide mechanism at all means `kind: "manual"`. ByHost plists go through `macos-console-user.sh` activation, never `system.defaults.CustomUserPreferences`.
