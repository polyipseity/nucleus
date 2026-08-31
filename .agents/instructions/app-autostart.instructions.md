---
description: "Use when adding, editing, or reviewing GUI/user app auto-start or menu-bar/tray-icon entries in apps.json or the convergence tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, Sync-MenuBar.ps1). Enforces the never-app-owned-startup policy, autostartDisableNative-first discipline, single uniform mechanism per platform, and the menu-bar icon registry."
name: "App Auto-Start & Menu-Bar Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh, src/scripts/menu-bar.sh, src/scripts/menu-bar.ps1, src/platforms/Windows/modules/user/Sync-MenuBar.ps1, src/hosts/MacBook/scripts/macos-configure-menu-bar-icons.sh, src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
---

# App auto-start registry

## Policy (hard constraint)

One mechanism per app per host controls auto-start — ours, never the app's native setting.

1. **Disable the app's native auto-start** wherever one exists: macOS "Open at Login" / Login Item checkbox, Windows in-app "Start at login" or a Run key the app writes, Linux an XDG `.desktop` the app ships. Disable declaratively when a managed preference exists (`defaults`/`plist`, Group Policy, `dconf`); otherwise disable imperatively per-run so the app cannot re-enable itself.
2. **Enable/disable via our single uniform mechanism** — a registry-driven, platform-specific launcher:
   - macOS: login items we add/remove via `osascript System Events`. Headless/system items use a LaunchAgent or system-extension entry we own. TCC caveat: the `osascript System Events` login-item path may require the script runner to be granted Accessibility under System Settings → Privacy & Security on first run (UI scripting). Activation surfaces a manual-approval reminder when the runner lacks the entitlement.
   - NixOS: an XDG autostart `.desktop` we write/remove in `~/.config/autostart/`.
   - Windows: a Run-key entry or Startup-folder `.lnk` we write/remove.

No app-native "enable" path is ever used as the control mechanism.

## Omission rule (hard constraint)

An app may be `omitted` on a host only when the software has no build or port for that platform. The omission must state platform inapplicability (e.g. "no Linux build exists"), not point at a substitute.

- Valid: WhatsApp on NixOS — "No Linux client exists; WhatsApp is macOS/Windows only."
- Invalid: "PowerToys provides the Windows equivalent" or "Linux uses the native service" — cite a substitute, not a platform constraint.

## Registry location and shape

- `src/modules/apps.json` is the SSOT for GUI/user app auto-start. Every entry declares per host: `autostartEnabled` (bool — launch it), `autostartDisableNative` (bool — disable the app's native setting), and `kind` (`login-item` | `launchagent` | `xdg-desktop` | `run-key` | `startup-folder` | `system-extension`).
- `autostartDisableNative` is first-class: the app's own setting is always disabled (imperatively if no declarative toggle exists).
- Schema: `src/modules/apps.schema.json` reuses shared parity definitions from `src/modules/registry-common.schema.json`. Every app requires `MacBook`/`NixOS`/`Windows` keys, or an explicit `omitted` + `justification` entry.
- Tooling: `src/scripts/autostart.sh` (POSIX) and `src/scripts/autostart.ps1` (Windows) mirror the `svc` CLI surface (`list`/`status`/`enable`/`disable`/`apply`/`verify`) but manage login bootstrap, not daemon lifecycle. They live under `src/scripts/` (convergence tooling invoked by activation scripts), NOT `scripts/` (reserved for `nucleus-*` apps). Windows convergence is invoked from `Sync-AppAutostart.ps1` during `apply.ps1`.

## Menu-bar / tray-icon registry (same SSOT)

Menu-bar / tray-icon visibility is converged from the same `apps.json` SSOT via a `menuBarIcon` block on each host entry. It is a distinct concern from auto-start:

- Auto-start is OR (app-native OR our login item ⇒ launches), so auto-start disables the native setting.
- Icon visibility is AND (icon shows only if the app-native show setting AND the OS both allow it). There is no separate "our mechanism" — the app's native preference is the control. The convergence tool sets it to the desired state; it never disables it.

`menuBarIcon` block fields (see `apps.schema.json` `menuBarIconEntry`):

- `iconVisible` (bool, required) — the desired end state (true = show, false = hide).
- `kind` (required) — `defaults-key` (macOS `defaults`/`plist` domain+key), `plist` (arbitrary plist path, e.g. LuLu's `/Library/Objective-See/LuLu/preferences.plist`), or `activation-script` (delegates to a host activation script).
- `domain` + `key` + `valueType` (`defaults-key`), or `plistPath` + `key` + `valueType` (`plist`).
- `iconVisibleValue` / `iconHiddenValue` (typed per `valueType`: bool/string/int) — the native value that means "visible" / "hidden". Inverted keys (e.g. BetterDisplay `hideMenuIcon`, Rectangle `hideMenubarIcon`, LuLu `noIconMode`) express the inversion here rather than via a disable flag: `iconVisible: false`, `iconVisibleValue: false`, `iconHiddenValue: true`.
- `justification` — required when the app is allow-listed (Amphetamine/Stats) or otherwise intentionally omits a `menuBarIcon` block.

Tooling mirrors the autostart CLI surface (`list`/`status`/`show`/`hide`/`apply`/`verify`): `src/scripts/menu-bar.sh` (POSIX) and `src/scripts/menu-bar.ps1` (Windows), invoked from `macos-configure-menu-bar-icons.sh` / `nixos-configure-menu-bar.sh` / `Sync-MenuBar.ps1`. `plist` kind on macOS restarts the owning daemon (via `pgrep`/`pkill` bundleId) so the new value takes effect.

## Boundary with `services.json`

- `services.json` = background daemons/agents (camilladsp, jellyfin, caddy, discord-music-rpc, etc.). Untouched by this registry.
- `apps.json` = foreground GUI apps the user launches at login (Raycast, Amphetamine, BetterDisplay, MiddleClick, Mounty, Stats, LinearMouse, LuLu, OrbStack, Parsec, Steam [disabled], Telegram, WhatsApp, battery, etc.).
- `battery` is a macOS menu-bar GUI app that auto-starts at login — it belongs in `apps.json` as a `login-item` entry, not `services.json`. The `battery` CLI is the same app's command interface, not a separate service.
- System-extension apps (fuse-t, Chrome Remote Desktop Host) are tracked in `apps.json` as `system-extension` entries (no exceptions) even though they cannot be force-launched — documented as manual-approval.

## Adding a new app

1. Add the app block to `apps.json` with `MacBook`/`NixOS`/`Windows` entries (or `omitted` + `justification`).
2. Set `autostartDisableNative: true` on every host where the app ships a native auto-start setting.
3. Pick the uniform `kind` per host from the allowed enum.
4. Run `src/scripts/autostart.sh apply` (or `autostart.ps1 apply` on Windows) to converge; `verify` must pass.
5. No backwards-compat shims: remove any ad-hoc per-app script in the same change that adds the registry entry.
