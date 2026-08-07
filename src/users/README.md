# User configuration

This tree holds per-user settings that land in home directories or feed the user registry. `default/` is the shared template. Each real user gets a sibling directory (`polyipseity/`, and so on) with overrides.

## Registry domains (`*.json`)

Files like `profile.json`, `cloud-drives.json`, and `dev-repos.json` live at the user root. Schemas sit next to the defaults in `default/*.schema.json`. Per-user files point at them with `"$schema": "../default/<domain>.schema.json"`.

Loaders merge `default/<file>` with `<username>/<file>` using a deep merge. Nested objects combine field by field; the user file wins when both set the same key. Arrays do not merge element by element. If the user file sets an array, it replaces the default array entirely. Per-user override files may omit top-level keys they do not change; domain schemas do not require unrelated fields to be present (only `default/` carries the full baseline).

Some fields accept either a plain string or a host map. Host maps use keys `MacBook`, `NixOS`, and `Windows` (same names as the flake host configurations). At load time the loader picks the value for the machine being configured and drops the map wrapper.

| Loader | Entry point |
|--------|-------------|
| Nix | `src/modules/lib/users-registry.nix` (`hostName` argument) |
| Shell | `src/scripts/lib/load-user-registry.sh --host MacBook\|NixOS\|Windows` |
| PowerShell | `src/hosts/Windows/modules/Load-UserRegistry.ps1` |

`symlinks.json` keeps its `targets` map intact in the registry; POSIX and Windows activation code resolves the right host entry when creating symlinks.

### Jellyfin union at sync time

`jellyfin.json` follows the same per-user deep merge as other registry domains: each real user's effective payload is `default/jellyfin.json` merged with `src/users/<username>/jellyfin.json` (arrays replace wholesale). The default file is empty (`accounts: []`, `libraries: []`) but still participates in that merge.

Jellyfin sync on the host is different: activation scripts union every user's merged `accounts` and `libraries` into one shared Jellyfin instance (dedup by account id and library name at sync time). See `src/scripts/services/jellyfin-sync.sh` and the Windows `Sync-Jellyfin*` modules.

## Homedir app trees (directories)

Folders such as `agents/`, `cursor/`, `git/`, and `wallpapers/` use a different rule: only first-level names participate in overlay. If `users/<user>/cursor/hooks.json` exists, it replaces `default/cursor/hooks.json` as a whole. You cannot override a single file inside `default/cursor/` without replacing the entire first-level entry (for example the whole `hooks/` directory).

Resolve paths through the overlay helpers (`mkUserOverlay`, `resolve_user_config_file`, `Resolve-UserConfigFile`, and related functions). Do not hardcode `src/users/default/...` in deployment code.

## Further reading

Placement rules and deployment methods live in `.agents/instructions/user-config-placement.instructions.md` and `app-config-policy.instructions.md`.
