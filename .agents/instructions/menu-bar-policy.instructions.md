---
description: "Use when provisioning or configuring macOS apps on the MacBook host. Mandates the default-hide menu bar icon policy, the amphetamine+stats allow-list, minimal NSStatusItem spacing, and per-app hide mechanisms. Menu-bar icon state is converged from the apps.json menuBarIcon registry (src/scripts/menu-bar.sh), not inline defaults.nix."
name: "macOS Menu Bar Icon Policy"
applyTo: "src/hosts/MacBook/**, src/modules/apps.json, src/modules/apps.schema.json"
---

# Menu bar icon policy

By default, hide all menu bar icons on the MacBook host. Configure both the app and macOS to hide the icon where possible. When asked to disable, disable as much as possible; when asked to enable, enable as much as possible. The default is disable.

## Allow-list

These apps keep a menu bar icon (enabled via the Control Center gate, class f):

- Amphetamine — menu-bar-only by design (LSUIElement); provisioned as the focus/energy tool.
- Stats — the user-visible monitoring surface; replaces the macOS battery percentage item.
- Mounty — NTFS remount surface; menu-bar-only by design.
- OrbStack — menu-bar-first VM/container manager.

Never set a hide key for allow-listed apps.

## Hide mechanisms

| Class | Mechanism | Examples |
| --- | --- | --- |
| a | Declarative preference key, converged from the `apps.json` `menuBarIcon` registry via `src/scripts/menu-bar.sh` | Raycast `ShowMenuBarIcon`, BetterDisplay `hideMenuIcon`, AltTab `menubarIconShown`, Rectangle `hideMenubarIcon`, LinearMouse `menuBarVisibilityMode`, LuLu `noIconMode` |
| b | ⌘-drag only (per-session; icon returns on relaunch) | MiddleClick (`statusItem.behavior = .removalAllowed`) |
| c | Icon is the app's primary UI — not hideable | Equaliser (menu-bar-only SwiftUI app) |
| d | No supported option | Parsec, Telegram, WhatsApp, Steam |
| e | macOS "Allow in the Menu Bar" user-level list only | (none — see class f) |
| f | macOS 26 Control Center `NSStatusItem` gate, converged declaratively from the `apps.json` `menuBarIcon` registry | Amphetamine, Stats, Mounty, OrbStack |

## System items

Hide Siri (`com.apple.Siri` `StatusMenuVisible`), Spotlight (`com.apple.Spotlight` `MenuItemHidden`, ByHost), the Input Menu (`com.apple.TextInputMenu.visible`), and the Control Centre battery item (`Battery = 12`, ByHost; Stats replaces it).

## Rules

- Set `NSStatusItemSpacing`/`NSStatusItemSelectionPadding` as low as possible: 0, falling back to 4 when icons overlap. Values below 4 are untested and may overlap.
- The macOS 26 Control Center `NSStatusItem` gate is managed declaratively. Write `defaults write com.apple.controlcenter "NSStatusItem Visible <BundleID>" -bool <true|false>` (true = allowed/shown, false = hidden; NOT inverted) from the `apps.json` `menuBarIcon` registry via `src/scripts/menu-bar.sh`. Pre-Tahoe this key is a harmless no-op (apps show by default). Do not write `menuItemLocations`; only the `NSStatusItem Visible <BundleID>` boolean is managed.
- Apps with no programmatic hide mechanism are still declared in `apps.json` with `kind: "manual"` and `provisioned: false` so the desired state is explicit and surfaced via `menu-bar.sh list/verify`. The engine never auto-provisions manual entries.
- ByHost plists (`defaults -currentHost`) cannot be written by `system.defaults.CustomUserPreferences`; use an activation script with the `macos-console-user.sh` pattern.
- Precedent: `homebrew.nix` declines provisioning apps whose menu bar chrome cannot be managed declaratively.
