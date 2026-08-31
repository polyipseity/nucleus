---
description: "Use when deciding whether a config belongs in src/modules/configs/ or src/users/, or when wiring per-user homedir overlay selectors."
name: "User Config Placement"
applyTo: "src/modules/configs/**, src/users/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, AGENTS.md"
---

# User config placement

## Placement taxonomy

### Machine-wide singleton — `src/modules/configs/`

One configuration location for the entire host. Adding a second managed nucleus user does not require a second repo file. Examples: system gitconfig, camilladsp, camillagui-backend, ssh/sshd, VM templates.

### Per-user homedir — `src/users/default/` + `src/users/<username>/`

One config instance per OS user via homedir deployment (usually writable symlink). `default/` is the default template; per-user entries override at the first level only (see overlay merge rule).

Examples: `agents/`, `cursor/`, `direnv/`, `plasma/desktop/`, `autocorrect/wordlist.txt`, `wallpapers/encrypted/*.sops`, `wallpapers/wallpapers/*.png`.

### Registry domains — `src/users/default/*.json`

Structured nucleus data (`profile.json`, `cloud-drives.json`, …) assembled by `users-registry.nix`. Schema files are co-located as `src/users/default/<domain>.schema.json`; per-user domain JSON uses `"$schema": "../default/<domain>.schema.json"`.

`cloud-drives.json` includes `replicaGc` (per-provider GC rules for replica sync) alongside `mounts` and `replicas`.

Registry domains deep-merge `default/` with `src/users/<username>/` via `lib.recursiveUpdate` (in `users-registry.nix`): the user file wins on conflicts, and array fields are replaced wholesale — this is intended, not a defect. A user who sets an array field replaces the default list entirely; element-wise union is not performed and must not be added. Fields that differ by host use maps keyed by `MacBook`, `NixOS`, and `Windows`; loaders resolve them to scalars for the current host. Jellyfin sync unions merged accounts and libraries across all users on the host — see `src/users/README.md` (Jellyfin union at sync time). Merge documentation lives in `users-registry.nix`.

**Testing:** Tests exercise user overlays via fixture trees or temp dirs — never by coupling to a production `src/users/<username>/` identity. See `testing.instructions.md` (No real-user test coupling).

## First-level overlay merge rule

Within an app config folder (e.g. `plasma/`, `cursor/`, `wallpapers/`), **only first-level files and directories** participate in overlay. Deeper paths never merge independently.

- `selectFile "plasma" "desktop/nucleus-manual.desktop"` — first-level key is `desktop/`; if `users/<user>/plasma/desktop/` exists, the entire directory wins; otherwise use `default/plasma/desktop/`.
- `selectFile "direnv" "lib/apple-sdk-override.sh"` — first-level key is `lib/`; user `direnv/lib/` overrides the whole default `lib/` tree.
- `wallpapers/encrypted/foo.png.sops` — first-level key is `encrypted/`; user `wallpapers/encrypted/` overrides the whole default `encrypted/` tree.
- `wallpapers/wallpapers/foo.png` — first-level key is `wallpapers/`; user `wallpapers/wallpapers/` overrides the whole default `wallpapers/` tree.

Directory-wide iteration uses `listFirstLevelEntries` / `list_user_config_first_level_entries` and resolves each entry with `selectFirstLevelEntry` / `resolve_user_config_first_level_entry`.

## Overlay coverage rule

Every app tree under `src/users/` MUST be consumed only through overlay selectors — never via a hardcoded `src/users/default/...` path in deployment code.

| Mechanism | POSIX | Windows | Shell scripts |
| ----------- | ------- | --------- | --------------- |
| Host-specific file | `mkUserOverlay` → `selectSource` | `Resolve-UserConfigSource` | N/A |
| File path (any depth) | `mkUserOverlay` → `selectFile` | `Resolve-UserConfigFile` / `Deploy-UserWritableSymlink` | `resolve_user_config_file` |
| First-level entry | `mkUserOverlay` → `selectFirstLevelEntry` | `Resolve-UserConfigFirstLevelEntry` | `resolve_user_config_first_level_entry` |
| First-level name list | `mkUserOverlay` → `listFirstLevelEntries` | `Get-UserConfigFirstLevelEntryList` | `list_user_config_first_level_entries` |
| Wallpaper encrypted blobs | `wallpaper-paths.nix` → `listEncryptedWallpaperBlobs` | `Get-WallpaperEncryptedBlobList` | `list_wallpaper_encrypted_blobs` |
| Wallpaper unencrypted files | `wallpaper-paths.nix` → `listUnencryptedWallpaperFiles` | `Get-WallpaperUnencryptedFileList` | `list_wallpaper_unencrypted_files` |
| Registry JSON | `users-registry.nix` (`hostName`) | `Load-UserRegistry.ps1` | `load-user-registry.sh --host` |

Allowed hardcoded `src/users/default/` references: inside the selector implementations themselves, registry loaders, and tests that assert default baseline content.

### Dual-scope apps

Split explicitly when an app supports both machine-wide and per-user scopes. Git is canonical: system scope in `src/modules/configs/git/`, user scope in `src/users/default/git/`.

## Wallpapers

Per-user homedir assets under `src/users/default/wallpapers/` + `src/users/<username>/wallpapers/`. The config folder has exactly two first-level entries:

| Subdirectory | Contents | Deploy method |
| -------------- | ---------- | --------------- |
| `encrypted/` | SOPS blobs (`*.sops`) | Method 2: decrypt → `~/Pictures/wallpapers/` |
| `wallpapers/` | Unencrypted images | Method 1: writable symlink → `~/Pictures/wallpapers/` |

Default empty subdirs ship with `.gitkeep`. Root `.gitignore` ignores decrypted/runtime artifacts under `encrypted/` while tracking `*.sops` blobs only; unencrypted images under `wallpapers/wallpapers/` are tracked intentionally.

## Anti-patterns

- Per-user homedir config in `src/modules/configs/` (blocks multi-user overlay; shared symlink collisions).
- Hardcoded `src/users/default/...` in deployment modules or activation scripts.
- Duplicate file in both `configs/` and `users/`.
- Mixing machine and user scope in one directory tree.
- Second-level overlay overrides (e.g. overriding a single file inside `default/plasma/desktop/` without replacing the whole `desktop/` first-level entry).

## Related instructions

- `app-config-policy.instructions.md` — deployment methods (writable symlink, merge, runtime read) within each scope.
- `git-scope-terminology.instructions.md` — dual-scope git reference implementation.
