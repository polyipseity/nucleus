---
description: "Use when provisioning or configuring macOS apps on the MacBook host. Mandates the default-hide menu bar icon policy, the amphetamine+stats allow-list, minimal NSStatusItem spacing, and per-app hide mechanisms."
name: "macOS Menu Bar Icon Policy"
applyTo: "src/hosts/MacBook/**"
---

# Menu bar icon policy

By default, hide all menu bar icons on the MacBook host. Configure both the app and macOS to hide an icon wherever a mechanism exists. When asked to disable icons, disable as much as possible; when asked to enable, enable as much as possible. The default is disable.

## Allow-list

Only these apps may keep a menu bar icon:

- Amphetamine — menu-bar-only by design (LSUIElement); provisioned as the focus/energy tool.
- Stats — the user-visible monitoring surface; replaces the macOS battery percentage item.

Never set a hide key for allow-listed apps.

## Hide mechanisms

| Class | Mechanism | Examples |
| --- | --- | --- |
| a | Declarative preference key, set in `defaults.nix` or an activation script | Raycast `ShowMenuBarIcon`, BetterDisplay `hideMenuIcon`, AltTab `menubarIconShown`, Rectangle `hideMenubarIcon`, LinearMouse `menuBarVisibilityMode`, LuLu `noIconMode` |
| b | ⌘-drag only (per-session; icon returns on relaunch) | MiddleClick (`statusItem.behavior = .removalAllowed`) |
| c | Icon is the app's primary UI — not hideable | Mounty (NTFS remount surface), Equaliser (menu-bar-only SwiftUI app) |
| d | No supported option | Parsec, battery tray app |
| e | macOS "Allow in the Menu Bar" user-level list only | OrbStack |

## System items

Hide Siri (`com.apple.Siri` `StatusMenuVisible`), Spotlight (`com.apple.Spotlight` `MenuItemHidden`, ByHost), the Input Menu (`com.apple.TextInputMenu.visible`), and the Control Centre battery item (`Battery = 12`, ByHost; Stats replaces it).

## Rules

- Set `NSStatusItemSpacing`/`NSStatusItemSelectionPadding` as low as possible: 0, falling back to 4 when icons overlap. Values below 4 are untested and may overlap.
- Never manage the macOS 26 "Allow in the Menu Bar" list declaratively: it is per-user GUI state keyed by bundle ID in `group.com.apple.controlcenter`, and a stale `menuItemLocations` entry can hide icons even when allowed. Document user-level steps in `MANUAL.md` instead.
- ByHost plists (`defaults -currentHost`) cannot be written by `system.defaults.CustomUserPreferences`; use an activation script with the `macos-console-user.sh` pattern.
- Precedent: `homebrew.nix` declines provisioning apps whose menu bar chrome cannot be managed declaratively.
