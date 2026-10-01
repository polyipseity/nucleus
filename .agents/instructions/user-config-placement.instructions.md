---
description: "Use when deciding whether a config belongs in src/modules/configs/ or src/users/, or when wiring per-user homedir overlay selectors."
name: "User Config Placement"
applyTo: "src/modules/configs/**, src/users/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, AGENTS.md"
---

# User config placement

Machine-wide singletons live in `src/modules/configs/`, one per host (system gitconfig, camilladsp, ssh/sshd, VM templates). Per-user homedir config lives in `src/users/default/` as the template plus `src/users/<username>/`, usually a writable symlink, and only first-level entries participate in the overlay. Registry domains are `src/users/default/*.json` with a co-located schema; per-user files point at `"$schema": "../default/<domain>.schema.json"`.

An app that supports both scopes splits: system in `src/modules/configs/`, user in `src/users/default/`. Git does this.

## Merge semantics

`users-registry.nix` deep-merges with `lib.recursiveUpdate`, so the user file wins and arrays are replaced wholesale by design. Host-varying fields use `MacBook`/`NixOS`/`Windows` maps that loaders resolve to scalars. `cloud-drives.json` carries `replicaGc` next to `mounts`/`replicas`; the Jellyfin sync unions accounts across users (`src/users/README.md`).

## Overlay selectors

Only first-level files and directories take part in the overlay, never deeper paths independently: `selectFile "plasma" "desktop/nucleus-manual.desktop"` gives the user `plasma/desktop/` entirely, and `wallpapers/encrypted/` replaces all defaults. Iteration uses `listFirstLevelEntries`, resolution uses `selectFirstLevelEntry`.

Every `src/users/` tree reaches its content through a selector, never a hardcoded `src/users/default/...` path in deployment code. Hardcoded references are allowed only in selector implementations, registry loaders, and default-baseline tests.

| Mechanism | POSIX | Windows | Shell |
| --- | --- | --- | --- |
| Host-specific file | `selectSource` | `Resolve-UserConfigSource` | N/A |
| File path (any depth) | `selectFile` | `Resolve-UserConfigFile` / `Deploy-UserWritableSymlink` | `resolve_user_config_file` |
| First-level entry | `selectFirstLevelEntry` | `Resolve-UserConfigFirstLevelEntry` | `resolve_user_config_first_level_entry` |
| First-level name list | `listFirstLevelEntries` | `Get-UserConfigFirstLevelEntryList` | `list_user_config_first_level_entries` |
| Wallpaper encrypted | `listEncryptedWallpaperBlobs` | `Get-WallpaperEncryptedBlobList` | `list_wallpaper_encrypted_blobs` |
| Wallpaper unencrypted | `listUnencryptedWallpaperFiles` | `Get-WallpaperUnencryptedFileList` | `list_unencrypted_wallpaper_files` |
| Registry JSON | `users-registry.nix` | `Load-UserRegistry.ps1` | `load-user-registry.sh --host` |

Wallpapers hold two entries under `src/users/default/wallpapers/`: `encrypted/` (SOPS blobs, decrypted to `~/Pictures/wallpapers/`) and `wallpapers/` (images, writable symlink to the same directory).

Testing uses fixture trees or temp dirs, never a production `src/users/<username>/` (`testing.instructions.md`).

## Anti-patterns

- Per-user config in `src/modules/configs/`, which blocks the overlay.
- Hardcoded `src/users/default/...` in deployment or activation code.
- The same config duplicated in `configs/` and `users/`.
- Machine and user scope mixed in one tree.
- Second-level overlay overrides.
