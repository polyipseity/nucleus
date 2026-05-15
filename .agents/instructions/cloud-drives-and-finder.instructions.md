---
description: "Use when editing cloud-drive mounts/replicas, cloud setup scripts, Finder favorites behavior, or related tests/manual docs."
name: "Cloud Drives and Finder Favorites"
applyTo: "src/modules/cloud-drives.nix, src/modules/macos.nix, src/hosts/windows/modules/user/Sync-CloudDrive.ps1, scripts/cloud-setup.sh, scripts/cloud-setup.ps1, scripts/replica-bisync.sh, scripts/replica-bisync.ps1, src/hosts/macbook/MANUAL.md, tests/nix/cloud-sync-tests.nix"
---

# Cloud Drives and Finder Favorites

## Scope

Use this guidance for cloud-drive convergence (mounts + replicas), related host
manual steps, and Finder favorites behavior on macOS.

## Canonical terminology (required)

- **Mounts**: live/on-demand access (`rclone mount`).
- **Replicas**: materialized local copy (`rclone sync`/`rclone bisync`).
- Keep this vocabulary consistent across Nix options, Windows user registry,
  scripts, docs, and tests.

## Path ownership invariants (required)

- Keep mount/replica local paths under managed user home paths (for example
  `~/clouds/*` or `%USERPROFILE%\clouds\*`).
- Managed mount/replica paths must be real directories by default on all hosts.
- If legacy symlinks/reparse points are found in managed cloud paths, migrate
  them to managed directories in-place during apply/setup.

### macOS-only iCloud exception

- Exactly one exception is allowed:
  - entry: provider `iCloud`, id `iCloud`, replica localPath `clouds/iCloudReplica`
  - behavior: `~/clouds/iCloudReplica` must be a symlink to
    `~/Library/Mobile Documents`
- WHY: this avoids duplicating native iCloud Drive storage with a second
  managed tree on macOS.
- Do not replicate this exception on NixOS or Windows.

## Finder favorites policy on modern macOS (required)

- Do **not** manage Finder favorites by writing `FavoriteItems.sfl*` archives
  directly via NSKeyedArchiver/JXA.
- Do **not** rely on deprecated/unsupported approaches (`sfltool`, abandoned
  `mysides`) as declarative guarantees.
- Preferred strategy:
  1. Ensure canonical directories exist (`~/dev`, `~/clouds`, cloud subpaths).
  2. Run one-time repair migration only when needed (marker-gated), backing up
     and removing known-bad legacy sidebar state payloads.
  3. Keep final favorite-item curation as a manual Finder UI step documented in
     `src/hosts/macbook/MANUAL.md`.

## Cloud setup/update behavior

- Treat remote IDs (`remoteName`, `id`) as stable identity keys.
- Update mutable metadata (for example display labels) only when changed; avoid
  rewriting remote config no-op fields.
- Keep `RCLONE_CONFIG_PASS` handling explicit and non-interactive once secrets
  are materialized.
- Validate remotes with root-only listings (`rclone lsd` on `/`) to avoid false
  positives from partially accessible subpaths.

## Windows parity rules for cloud modules

- Keep cloud path convergence in reusable user modules, not in ad-hoc
  orchestrator snippets.
- Detect and handle reparse points explicitly when checking path state.
- Keep configuration idempotent: repeated applies should converge without
  duplicate mounts/dirs or repeated destructive work.

## Tests and docs coupling (required)

When changing cloud-drive/Finder behavior, update all of the following in the
same change:

- `tests/nix/cloud-sync-tests.nix` expectations and test names.
- Host manual instructions (`src/hosts/macbook/MANUAL.md`) for manual Finder
  favorites steps.
- Inline WHY comments for every platform-specific exception.

Avoid stale assertions that refer to removed flags or deprecated implementation
paths.
