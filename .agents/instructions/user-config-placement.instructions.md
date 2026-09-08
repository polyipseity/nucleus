---
description: "Use when deciding whether a config belongs in src/modules/configs/ or src/users/, or when wiring per-user homedir overlay selectors."
name: "User Config Placement"
applyTo: "src/modules/configs/**, src/users/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, AGENTS.md"
---

# User config placement

## Placement taxonomy

**Machine-wide singleton — `src/modules/configs/`**. One location per host. Examples: system gitconfig, camilladsp, camillagui-backend, ssh/sshd, VM templates.

**Per-user homedir — `src/users/default/` + `src/users/<username>/`**. One per OS user (usually writable symlink). `default/` is template; per-user overrides first-level only. Examples: `agents/`, `cursor/`, `direnv/`, `plasma/desktop/`, `autocorrect/wordlist.txt`, `wallpapers/encrypted/*.sops`, `wallpapers/wallpapers/*.png`.

**Registry domains — `src/users/default/*.json`**. Structured data assembled by `users-registry.nix`. Schema: `src/users/default/<domain>.schema.json`; per-user uses `"$schema": "../default/<domain>.schema.json"`. `cloud-drives.json` includes `replicaGc` alongside `mounts`/`replicas`.

Deep-merge via `lib.recursiveUpdate` (in `users-registry.nix`): user file wins, arrays replaced wholesale — by design. Host-varying fields use `MacBook`/`NixOS`/`Windows` maps; loaders resolve to scalars. Jellyfin sync unions accounts across users (`src/users/README.md`). Merge docs in `users-registry.nix`.

Testing: fixture trees or temp dirs only — never production `src/users/<username>/` (see `testing.instructions.md`).

## First-level overlay merge rule

Only **first-level** files and directories participate in overlay. Deeper paths never merge independently.

- `selectFile "plasma" "desktop/nucleus-manual.desktop"` — key `desktop/`; user `plasma/desktop/` wins entirely.
- `selectFile "direnv" "lib/apple-sdk-override.sh"` — key `lib/`; user overrides whole default `lib/`.
- `wallpapers/encrypted/` or `wallpapers/wallpapers/` — user dir overrides all defaults.

Iteration: `listFirstLevelEntries` / `list_user_config_first_level_entries`. Resolution: `selectFirstLevelEntry` / `resolve_user_config_first_level_entry`.

## Overlay coverage rule

Every `src/users/` tree MUST use overlay selectors — never hardcoded `src/users/default/...` in deployment code.

| Mechanism | POSIX | Windows | Shell |
| --- | --- | --- | --- |
| Host-specific file | `selectSource` | `Resolve-UserConfigSource` | N/A |
| File path (any depth) | `selectFile` | `Resolve-UserConfigFile` / `Deploy-UserWritableSymlink` | `resolve_user_config_file` |
| First-level entry | `selectFirstLevelEntry` | `Resolve-UserConfigFirstLevelEntry` | `resolve_user_config_first_level_entry` |
| First-level name list | `listFirstLevelEntries` | `Get-UserConfigFirstLevelEntryList` | `list_user_config_first_level_entries` |
| Wallpaper encrypted | `listEncryptedWallpaperBlobs` | `Get-WallpaperEncryptedBlobList` | `list_wallpaper_encrypted_blobs` |
| Wallpaper unencrypted | `listUnencryptedWallpaperFiles` | `Get-WallpaperUnencryptedFileList` | `list_wallpaper_unencrypted_files` |
| Registry JSON | `users-registry.nix` | `Load-UserRegistry.ps1` | `load-user-registry.sh --host` |

Allowed hardcoded references: selector implementations, registry loaders, default-baseline tests.

### Dual-scope apps

Split when app supports both scopes. Git: system in `src/modules/configs/git/`, user in `src/users/default/git/`.

## Wallpapers

Assets under `src/users/default/wallpapers/` + `src/users/<username>/wallpapers/`. Two first-level entries: `encrypted/` (SOPS blobs, deploy: decrypt → `~/Pictures/wallpapers/`) and `wallpapers/` (unencrypted images, deploy: writable symlink → `~/Pictures/wallpapers/`). Empty subdirs ship `.gitkeep`.

## Anti-patterns

- Per-user config in `src/modules/configs/` (blocks overlay).
- Hardcoded `src/users/default/...` in deployment/activation code.
- Duplicate in both `configs/` and `users/`.
- Mixed machine/user scope in one tree.
- Second-level overlay overrides (single file inside a first-level dir without replacing the dir).
