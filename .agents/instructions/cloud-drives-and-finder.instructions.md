---
description: "Use when editing cloud-drive mounts/replicas, cloud setup scripts, Finder favorites behavior, or related tests/manual docs."
name: "Cloud Drives and Finder Favorites"
applyTo: "src/modules/cloud-drives.nix, src/platforms/macOS/modules/default.nix, src/platforms/Windows/modules/user/Sync-CloudDriveCatalog.ps1, src/platforms/Windows/modules/system/Invoke-ReplicaSync.ps1, scripts/cloud.sh, scripts/cloud.ps1, src/hosts/MacBook/MANUAL.md, src/hosts/NixOS/MANUAL.md, src/hosts/Windows/MANUAL.md"
---

# Cloud drives and Finder favorites

## Terminology

Mounts are live access through `rclone mount`, replicas are a materialized local copy through `rclone sync` (pull-only, remote to local). Keep the vocabulary consistent across Nix options, the Windows registry, scripts, and tests.

Replica automation must never write to a remote: no push and no bisync path in scripts, wrappers, scheduled tasks, or tests.

## Path ownership

Mount and replica local paths live under managed user home paths (`~/clouds/*`, `%USERPROFILE%\clouds\*`) and must be real directories on every host. A managed path that is a symlink or reparse point fails apply and setup with a clear error. Windows checks reparse points explicitly.

On macOS, `~/clouds/iCloudReplica` symlinks to `~/Library/Mobile Documents` so native iCloud Drive storage is not duplicated.

## Setup and update

Treat remote ids (`remoteName`, `id`) as stable identity keys and update mutable metadata such as display labels only when they change. Keep `RCLONE_CONFIG_PASS` handling explicit and non-interactive once secrets materialize. Validate a remote with a root-level `rclone lsd` on `/`, since a partially accessible subpath otherwise looks valid. Path convergence belongs in the reusable user modules, and repeated applies must converge without duplicate mounts or directories.

## Finder favorites

Do not write `FavoriteItems.sfl*` archives with NSKeyedArchiver or JXA, and do not rely on `sfltool`. Instead, ensure the canonical directories exist (`~/dev`, `~/clouds`, standard user folders), then enforce the exact ordered list with `mysides` in activation; `mysides add` takes URI-encoded URLs (space as `%20`), encoded through Nix `builtins.replaceStrings` rather than in the shell. Restart Finder, sharedfilelistd, and cfprefsd afterwards, and log a logout/login hint when the sidebar cache stays stale.

## Replica sync performance

rclone's listing and comparison phase is slow: expect 5-15 minutes for a full-root incremental sync. Runtime sync paths keep backend defaults and take no throttle flags (`--checkers 1`, `--transfers 1`); only bounded root-access probes may be defensive, and inter-run spacing has to accommodate a multi-minute run.

Platform-specific exceptions carry an inline WHY comment, and behavior that cannot be automated gets a host `MANUAL.md` step in the same change. Drop assertions that refer to removed flags or deprecated paths.
