---
description: "Use when adding, editing, or reviewing GUI/user app auto-start entries in apps.json or the autostart tooling (src/scripts/autostart.sh, src/scripts/autostart.ps1, Sync-AppAutostart.ps1). Enforces the never-app-owned-startup policy, autostartDisableNative-first discipline, and single uniform mechanism per platform."
name: "App Auto-Start Registry"
applyTo: "src/modules/apps.json, src/modules/apps.schema.json, src/scripts/autostart.sh, src/scripts/autostart.ps1, src/platforms/Windows/modules/user/Sync-AppAutostart.ps1, src/hosts/MacBook/scripts/macos-configure-app-autostart.sh, src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh"
---

# App auto-start registry

## Policy (hard constraint)

We **never let an app manage its own startup**. For every GUI/user app on every host there is exactly **one** mechanism that controls auto-start, and it is **ours** — never the app's native setting.

1. **Disable the app's native auto-start setting** wherever one exists. macOS "Open at Login" / Login Item checkbox; Windows in-app "Start at login" or a Run key the app writes; Linux an XDG `.desktop` the app ships. Disable **declaratively** when the app exposes a managed preference (`defaults`/`plist`, Group Policy, `dconf`); when no declarative path exists, disable **imperatively** (best-effort per-run) so the app's setting can never re-enable itself.
2. **Enable/disable via our single uniform mechanism** — a registry-driven, platform-specific launcher we fully own:
   - macOS: login items we add/remove via `osascript System Events` (our mechanism, not the app's checkbox). Headless/system items use a LaunchAgent or system-extension entry we own. **TCC caveat:** the `osascript System Events` login-item path may require the script runner to be granted **Accessibility** under System Settings → Privacy & Security on first run (UI scripting). Activation surfaces a manual-approval reminder when the runner lacks the entitlement.
   - NixOS: an XDG autostart `.desktop` we write/remove in `~/.config/autostart/`.
   - Windows: a Run-key entry or Startup-folder `.lnk` we write/remove.

No app-native "enable" path is ever used as the control mechanism.

## Omission rule (hard constraint)

An app may be `omitted` on a host **only** when the software has no build or port for that platform — i.e. it does not apply to that host at all. Citing an *equivalent* app or a *native service* as the reason for omission is **not** valid: every platform must run the same app, and where the app cannot run, the omission must state platform inapplicability (e.g. "no Linux build exists"), not point at a substitute.

- **Valid omission**: WhatsApp on NixOS — "No Linux client exists; WhatsApp is macOS/Windows only." (no Linux binary of any kind).
- **Invalid omission**: "PowerToys provides the Windows equivalent" or "Linux uses the native service" — these cite a substitute and must be replaced with a platform-inapplicability statement.

## Registry location and shape

- `src/modules/apps.json` is the SSOT for GUI/user app auto-start. Every entry declares per host: `autostartEnabled` (bool — do we launch it), `autostartDisableNative` (bool — does the app ship a native setting we must turn off), and the uniform `kind` (`login-item` | `launchagent` | `xdg-desktop` | `run-key` | `startup-folder` | `system-extension`).
- `autostartDisableNative` is **first-class**: the app's own setting is always disabled (imperatively if a declarative toggle is impossible). This guarantees a single source of truth for enable/disable.
- Schema: `src/modules/apps.schema.json` reuses shared parity definitions from `src/modules/registry-common.schema.json` (same machinery as `services.schema.json`). Every app requires `MacBook`/`NixOS`/`Windows` keys, or an explicit `omitted` + `justification` entry, enforcing parity-first at validation time.
- Tooling: `src/scripts/autostart.sh` (POSIX) and `src/scripts/autostart.ps1` (Windows) mirror the `svc` CLI surface (`list`/`status`/`enable`/`disable`/`apply`/`verify`) but manage login bootstrap, not daemon lifecycle. They live under `src/scripts/` (convergence tooling invoked by activation scripts), NOT `scripts/` (which is reserved for `nucleus-*` apps). Windows convergence is invoked from `Sync-AppAutostart.ps1` during `apply.ps1`.

## Boundary with `services.json`

- `services.json` = background daemons/agents (camilladsp, jellyfin, caddy, discord-music-rpc, etc.). **Untouched** by this registry.
- `apps.json` = foreground GUI apps the user launches at login (Raycast, Amphetamine, BetterDisplay, MiddleClick, Mounty, Stats, LinearMouse, LuLu, OrbStack, Parsec, Steam [disabled], Telegram, WhatsApp, battery, etc.).
- **`battery` is a GUI login item** — a macOS menu-bar GUI app that auto-starts at login. It also ships a `battery` CLI, but that is the same app's command interface, not a separate service. It belongs in `apps.json` as a `login-item` entry, not `services.json`.
- Tray/background apps already in `services.json` stay there. Only genuinely GUI apps move to `apps.json`. System-extension apps (fuse-t, Chrome Remote Desktop Host) are tracked in `apps.json` as `system-extension` entries (per policy: track everything, no exceptions) even though they cannot be force-launched — documented as manual-approval.

## Adding a new app

1. Add the app block to `apps.json` with `MacBook`/`NixOS`/`Windows` entries (or `omitted` + `justification`).
2. Set `autostartDisableNative: true` on every host where the app ships a native auto-start setting.
3. Pick the uniform `kind` per host from the allowed enum.
4. Run `src/scripts/autostart.sh apply` (or `autostart.ps1 apply` on Windows) to converge; `verify` must pass.
5. No backwards-compat shims: remove any ad-hoc per-app script in the same change that adds the registry entry.
