---
description: "Use when adding, editing, or reviewing GUI/user app auto-start or menu-bar/tray-icon entries in apps.json or the convergence tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, Sync-MenuBar.ps1). Enforces the never-app-owned-startup policy, autostartDisableNative-first discipline, single uniform mechanism per platform, and the menu-bar icon registry."
name: "App Auto-Start & Menu-Bar Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, src/platforms/Windows/modules/user/Sync-MenuBar.ps1, src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh, src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
---

# App auto-start registry

## Policy

One mechanism per app per host — ours, never the app's.

1. **Disable native auto-start** wherever one exists: macOS "Open at Login", Windows Run key, Linux XDG `.desktop`. Disable declaratively (`defaults`/`plist`, Group Policy, `dconf`) or imperatively per-run.
2. **Enable/disable via uniform mechanism** — registry-driven, platform-specific:
   - macOS: login items via `osascript System Events`. Headless/system: LaunchAgent or system-extension. TCC: script runner may need Accessibility on first run; activation surfaces reminder.
   - NixOS: XDG autostart `.desktop` in `~/.config/autostart/`.
   - Windows: Run-key or Startup-folder `.lnk`.

## Omission rule

`omitted` only when software has no build for that platform. State platform inapplicability, not a substitute. Valid: WhatsApp/NixOS "No Linux client". Invalid: "PowerToys provides the equivalent".

## Registry location and shape

- `src/modules/apps.json` — SSOT. Per-host: `autostartEnabled` (bool), `autostartDisableNative` (bool), `kind` (`login-item` | `launchagent` | `xdg-desktop` | `run-key` | `startup-folder` | `system-extension`).
- `autostartDisableNative` always-on: native setting disabled even without declarative toggle.
- Schema: `src/modules/apps.schema.json` reuses `src/modules/registry-common.schema.json`. Each app needs `MacBook`/`NixOS`/`Windows` keys, or `omitted` + `justification`.
- Tooling: `src/scripts/autostart.sh`/`.ps1` — `list`/`status`/`enable`/`disable`/`apply`/`verify`. Under `src/scripts/` (convergence), not `scripts/` (`nucleus-*`). Windows invoked from `Sync-AppAutostart.ps1`.

## Menu-bar / tray-icon registry (same SSOT)

Converged from `apps.json` via `menuBarIcon` block per host. Distinct from auto-start: auto-start is OR → disables native; icon is AND → convergence sets desired state, never disables.

`menuBarIcon` fields (see `apps.schema.json` `menuBarIconEntry`):

- `iconVisible` (bool, required), `kind` (required) — `defaults-key`, `plist`, or `activation-script`.
- `defaults-key`: `domain` + `key` + `valueType`. `plist`: `plistPath` + `key` + `valueType`.
- `iconVisibleValue`/`iconHiddenValue` — typed per `valueType`. Inverted keys (BetterDisplay `hideMenuIcon`, Rectangle `hideMenubarIcon`, LuLu `noIconMode`): `iconVisible: false`, `iconVisibleValue: false`, `iconHiddenValue: true`.
- `justification` — required for allow-listed apps or when block intentionally omitted.

Tooling: `src/scripts/menu-bar.sh`/`.ps1` — `list`/`status`/`show`/`hide`/`apply`/`verify`. `plist` kind restarts owning daemon via `pgrep`/`pkill` bundleId.

## Boundary with `services.json`

- `services.json` = background daemons/agents (camilladsp, jellyfin, caddy). Untouched.
- `apps.json` = foreground GUI apps at login (Raycast, Amphetamine, BetterDisplay, etc.).
- `battery` = menu-bar GUI → `apps.json` `login-item`, not `services.json`.
- System-extension apps (fuse-t, Chrome Remote Desktop Host) = `system-extension` entries, manual-approval.

## Adding a new app

1. Add block to `apps.json` with host entries (or `omitted` + `justification`).
2. `autostartDisableNative: true` on every host with native auto-start.
3. Pick `kind` per host from enum.
4. `autostart.sh apply`/`autostart.ps1 apply`; `verify` must pass.
5. Remove ad-hoc per-app script in same change — no compat shims.

## Menu bar icon policy

Default: hide all MacBook menu bar icons. Configure both app and macOS to hide where possible.

### Allow-list (class f — Control Center gate)

Amphetamine (menu-bar-only, LSUIElement), Stats (monitoring, replaces battery), Mounty (NTFS remount, menu-bar-only), OrbStack (VM/container manager). Never set hide key for these.

### Hide mechanisms

| Class | Mechanism | Examples |
| --- | --- | --- |
| a | Declarative via `apps.json` `menuBarIcon` | Raycast, BetterDisplay, AltTab, Rectangle, LinearMouse, LuLu |
| b | ⌘-drag (per-session) | MiddleClick |
| c | Primary UI — not hideable | Equaliser |
| d | No supported option | Parsec, Telegram, WhatsApp, Steam |
| f | macOS 26 Control Center `NSStatusItem` gate | Amphetamine, Stats, Mounty, OrbStack |

### System items

Hide Siri (`com.apple.Siri` `StatusMenuVisible`), Spotlight (`com.apple.Spotlight` `MenuItemHidden`, ByHost), Input Menu (`com.apple.TextInputMenu.visible`), battery (`Battery = 12`, ByHost).

### Rules

- `NSStatusItemSpacing`/`NSStatusItemSelectionPadding`: 0 min, fallback 4 on overlap.
- macOS 26 gate: `defaults write com.apple.controlcenter "NSStatusItem Visible <BundleID>"` via `menu-bar.sh`. Pre-Tahoe: no-op.
- No hide mechanism: declare `kind: "manual"`, `provisioned: false`.
- ByHost plists: use activation script with `macos-console-user.sh` pattern, not `system.defaults.CustomUserPreferences`.
