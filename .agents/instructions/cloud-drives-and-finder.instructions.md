---
description: "Use when editing cloud-drive mounts/replicas, cloud setup scripts, Finder favorites behavior, or related tests/manual docs."
name: "Cloud Drives and Finder Favorites"
applyTo: "src/modules/cloud-drives.nix, src/modules/macos.nix, src/hosts/Windows/modules/user/Sync-CloudDrive.ps1, src/hosts/Windows/modules/system/Invoke-ReplicaSync.ps1, scripts/cloud-setup.sh, scripts/cloud-setup.ps1, scripts/replica-sync.sh, scripts/replica-sync.ps1, src/hosts/MacBook/MANUAL.md, src/hosts/NixOS/MANUAL.md, src/hosts/Windows/MANUAL.md, tests/integration/cloud-sync-tests.nix"
---

# Cloud Drives and Finder Favorites

## Canonical terminology

- **Mounts**: live/on-demand access (`rclone mount`).
- **Replicas**: materialized local copy (`rclone sync` pull-only, remote -> local).
- Keep this vocabulary consistent across Nix options, Windows user registry, scripts, docs, and tests.
- Replica automation must not write to remotes: no push paths and no bisync paths in scripts, wrappers, scheduled tasks, or tests.

## Path ownership invariants

- Keep mount/replica local paths under managed user home paths (for example `~/clouds/*` or `%USERPROFILE%\clouds\*`).
- Managed mount/replica paths must be real directories by default on all hosts.
- If legacy symlinks/reparse points are found in managed cloud paths, migrate them to managed directories in-place during apply/setup.

### macOS-only iCloud exception

- Exactly one exception is allowed:
  - entry: provider `iCloud`, id `iCloud`, replica localPath `clouds/iCloudReplica`
  - behavior: `~/clouds/iCloudReplica` must be a symlink to `~/Library/Mobile Documents`
- WHY: this avoids duplicating native iCloud Drive storage with a second managed tree on macOS.
- Do not replicate this exception on NixOS or Windows.

## Finder favorites policy on modern macOS

- Do **not** manage Finder favorites by writing `FavoriteItems.sfl*` archives directly via NSKeyedArchiver/JXA.
- Do **not** rely on `sfltool` for favorites management.
- Preferred strategy:
  1. Ensure canonical directories exist (`~/dev`, `~/clouds`, and standard user folders referenced by favorites).
  2. Use `mysides` in activation to enforce an exact ordered favorites list.
     - `mysides add` expects properly URI-encoded URLs. Spaces must be `%20`.
     - Encode all `file://` URLs using Nix's `builtins.replaceStrings` before passing to `mysides`. Do not rely on shell-level encoding.
  3. Restart Finder/sharedfilelistd/cfprefsd in-session after updates; if sidebar cache remains stale, emit a one-line logout/login hint in logs.

## Cloud setup/update behavior

- Treat remote IDs (`remoteName`, `id`) as stable identity keys.
- Update mutable metadata (for example display labels) only when changed; avoid rewriting remote config no-op fields.
- Keep `RCLONE_CONFIG_PASS` handling explicit and non-interactive once secrets are materialized.
- Validate remotes with root-only listings (`rclone lsd` on `/`) to avoid false positives from partially accessible subpaths.

## Windows parity rules for cloud modules

- Keep cloud path convergence in reusable user modules, not in ad-hoc orchestrator snippets.
- Detect and handle reparse points explicitly when checking path state.
- Keep configuration idempotent: repeated applies should converge without duplicate mounts/dirs or repeated destructive work.

## Replica sync performance constraints

rclone's remote listing/comparison phase is inherently slow — expect multi-minute runtimes even for incremental syncs (5–15 min for full-root). Accept this as the trade-off for safe pull-only idempotent replication.

- **Do not force throttle flags** (`--checkers 1`, `--transfers 1`, etc.) in runtime sync paths unless a temporary exception is required. Bounded root-access probes (e.g., OneDrive inaccessible-root filtering) may use defensive flags; the real sync path must use backend defaults.
- **Schedule adequately**: inter-run spacing must accommodate multi-minute runtime.

## Tests and docs coupling

When changing cloud-drive/Finder behavior, update all of the following in the same change:

- `tests/integration/cloud-sync-tests.nix` expectations and test names.
- Inline WHY comments for every platform-specific exception.

Avoid stale assertions that refer to removed flags or deprecated implementation paths.
