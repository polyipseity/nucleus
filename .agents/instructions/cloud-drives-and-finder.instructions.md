---
description: "Use when editing cloud-drive mounts/replicas, cloud setup scripts, Finder favorites behavior, or related tests/manual docs."
name: "Cloud Drives and Finder Favorites"
applyTo: "src/modules/cloud-drives.nix, src/platforms/macOS/modules/default.nix, src/platforms/Windows/modules/user/Sync-CloudDriveCatalog.ps1, src/platforms/Windows/modules/system/Invoke-ReplicaSync.ps1, scripts/cloud.sh, scripts/cloud.ps1, src/hosts/MacBook/MANUAL.md, src/hosts/NixOS/MANUAL.md, src/hosts/Windows/MANUAL.md"
---

# Cloud Drives and Finder Favorites

## Terminology

- **Mounts**: live/on-demand access (`rclone mount`).
- **Replicas**: materialized local copy (`rclone sync` pull-only, remote → local).
- Keep vocabulary consistent across Nix options, Windows registry, scripts, docs, tests.
- Replica automation must not write to remotes: no push or bisync paths in scripts, wrappers, scheduled tasks, or tests.

## Path ownership

- Mount/replica local paths live under managed user home paths (e.g. `~/clouds/*` or `%USERPROFILE%\clouds\*`).
- Managed paths must be real directories by default on all hosts.
- If a managed path is a symlink or reparse point, apply/setup must fail with a clear error.

### macOS-only iCloud exception

- One exception allowed: provider `iCloud`, id `iCloud`, replica localPath `clouds/iCloudReplica`.
- `~/clouds/iCloudReplica` must symlink to `~/Library/Mobile Documents`. WHY: avoids duplicating native iCloud Drive storage.
- Do not replicate this exception on NixOS or Windows.

## Finder favorites (modern macOS)

- Do not manage Finder favorites by writing `FavoriteItems.sfl*` archives directly via NSKeyedArchiver/JXA.
- Do not rely on `sfltool`.
- Preferred approach:
  1. Ensure canonical directories exist (`~/dev`, `~/clouds`, standard user folders).
  2. Use `mysides` in activation to enforce an exact ordered favorites list. `mysides add` expects URI-encoded URLs (spaces = `%20`). Encode `file://` URLs via Nix's `builtins.replaceStrings`, not shell-level encoding.
  3. Restart Finder/sharedfilelistd/cfprefsd after updates; if sidebar cache stays stale, emit a logout/login hint in logs.

## Cloud setup/update

- Treat remote IDs (`remoteName`, `id`) as stable identity keys.
- Update mutable metadata (e.g. display labels) only when changed.
- Keep `RCLONE_CONFIG_PASS` handling explicit and non-interactive after secrets materialize.
- Validate remotes with root-only listings (`rclone lsd` on `/`) to avoid false positives from partially accessible subpaths.

## Windows parity

- Cloud path convergence in reusable user modules, not ad-hoc orchestrator snippets.
- Handle reparse points explicitly when checking path state.
- Configuration idempotent: repeated applies converge without duplicate mounts/dirs.

## Replica sync performance

rclone's listing/comparison phase is slow — expect 5–15 min for full-root incremental syncs. This is the trade-off for pull-only idempotent replication.

- Do not force throttle flags (`--checkers 1`, `--transfers 1`) in runtime sync paths. Bounded root-access probes may use defensive flags; the real sync path uses backend defaults.
- Inter-run spacing must accommodate multi-minute runtime.

## Tests and docs coupling

When changing cloud-drive/Finder behavior, update in the same change:

- Inline WHY comments for every platform-specific exception.
- Host `MANUAL.md` steps when behavior cannot be automated.

Do not leave stale assertions referring to removed flags or deprecated paths.
