---
description: "Use when adding, editing, or reviewing GUI/user app auto-start or menu-bar/tray-icon entries in apps.json or the convergence tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, Sync-MenuBar.ps1). Enforces the never-app-owned-startup policy, autostartDisableNative-first discipline, single uniform mechanism per platform, and the menu-bar icon registry."
name: "App Auto-Start & Menu-Bar Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, src/platforms/Windows/modules/user/Sync-MenuBar.ps1, src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh, src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
---

# App auto-start registry

## Policy

One mechanism per app per host — ours, never the app's.

1. **Disable native auto-start**: macOS "Open at Login", Windows Run key, Linux XDG `.desktop`. Declaratively or imperatively per-run.
2. **Uniform mechanism**: macOS nucleus-owned LaunchAgent plist (`~/Library/LaunchAgents/local.<bundle-id>.plist`, written by `autostart.sh`); NixOS XDG `.desktop`; Windows Run-key/Startup-folder `.lnk`. TCC: script runner may need Accessibility on first run.
3. **Neutralise the app's own agent**: for macOS login-item apps, `autostartDisableNative` removes the app-owned plist in both plist forms (`ProgramArguments` array and scalar `Program`) — recognising only one form leaves the app starting twice. Embedded Service-Management helpers (`Contents/Library/LoginItems`) cannot be unregistered by a script on macOS 13+; disable those in the app's own settings and record the app as not fully convergent.

`omitted` only when no build exists for platform. State inapplicability, not a substitute.

## Registry

`src/modules/apps.json` — SSOT. Per-host: `autostartEnabled`, `autostartDisableNative` (bool), `kind` (`login-item` | `launchagent` | `xdg-desktop` | `run-key` | `startup-folder` | `system-extension`). `autostartDisableNative` always-on. Schema: `src/modules/apps.schema.json` + `src/modules/registry-common.schema.json`. Each app: host keys or `omitted`+`justification`.

Tooling: `src/scripts/autostart.sh`/`.ps1` — `list`/`status`/`enable`/`disable`/`apply`/`verify`. Under `src/scripts/`, not `scripts/`. Windows: `Sync-AppAutostart.ps1`.

`services.json` = background daemons. `apps.json` = foreground GUI. `battery` = menu-bar GUI → `apps.json`. System-extension = manual-approval.

## Menu-bar / tray-icon (same SSOT)

Auto-start OR → disables native; icon AND → sets state, never disables. Converged from `apps.json` `menuBarIcon` block.

Fields (`apps.schema.json` `menuBarIconEntry`): `iconVisible` (bool), `kind` (`defaults-key` | `plist` | `activation-script`). `defaults-key`: `domain`+`key`+`valueType`. `plist`: `plistPath`+`key`+`valueType`. `iconVisibleValue`/`iconHiddenValue` per `valueType`. Inverted: `iconVisible: false`, `iconVisibleValue: false`, `iconHiddenValue: true` (BetterDisplay, Rectangle, LuLu `noIconMode`). `justification` for allow-listed apps or omitted blocks.

Tooling: `src/scripts/menu-bar.sh`/`.ps1` — `list`/`status`/`show`/`hide`/`apply`/`verify`. `plist` restarts daemon via `pgrep`/`pkill` bundleId.

## Adding a new app

1. Block in `apps.json` with host keys or `omitted`+`justification`.
2. `autostartDisableNative: true` where native auto-start exists.
3. Pick `kind` per host. 4. `autostart.sh apply`; `verify` passes. 5. Remove ad-hoc script same change.

## Menu bar icon policy

Default: hide all MacBook icons.

**Allow-list** (class f): Amphetamine (LSUIElement), Stats (replaces battery), Mounty (NTFS, menu-bar-only), OrbStack (VM/container). Never hide.

| Class | Mechanism | Examples |
| --- | --- | --- |
| a | Declarative `apps.json` `menuBarIcon` | Raycast, BetterDisplay, AltTab, Rectangle, LinearMouse, LuLu |
| b | ⌘-drag (per-session) | MiddleClick |
| c | Primary UI | Equaliser |
| d | No option | Parsec, Telegram, WhatsApp, Steam |
| f | macOS 26 `NSStatusItem` gate | Amphetamine, Stats, Mounty, OrbStack |

**System items**: Siri (`StatusMenuVisible`), Spotlight (`MenuItemHidden`, ByHost), Input Menu (`TextInputMenu.visible`), battery (`Battery = 12`, ByHost).

**Rules**: Spacing `NSStatusItemSpacing`/`NSStatusItemSelectionPadding` 0 min, fallback 4 on overlap. macOS 26 gate: `defaults write com.apple.controlcenter "NSStatusItem Visible <BundleID>"` via `menu-bar.sh`; pre-Tahoe no-op. No hide mechanism: `kind: "manual"`, `provisioned: false`. ByHost plists: `macos-console-user.sh` activation, not `system.defaults.CustomUserPreferences`.
