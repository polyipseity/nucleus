---
description: "Use when editing cloud-drive mounts, replicas, Finder favorites, or related setup scripts and tests."
name: "Cloud Drives and Finder Favorites"
applyTo: "src/modules/cloud-drives.nix, src/platforms/macOS/modules/default.nix, src/platforms/Windows/modules/user/Sync-CloudDriveCatalog.ps1, src/platforms/Windows/modules/system/Invoke-ReplicaSync.ps1, scripts/cloud.sh, scripts/cloud.ps1, src/hosts/MacBook/MANUAL.md, src/hosts/NixOS/MANUAL.md, src/hosts/Windows/MANUAL.md"
---

# Cloud drives and Finder favorites

Mounts use `rclone mount`; replicas use pull-only `rclone sync`. No push, bisync, or remote writes in scripts, wrappers, tasks, or tests. Local paths stay under `~/clouds/*` or `%USERPROFILE%\clouds\*` and must be real directories; a symlink or reparse point fails apply and setup. macOS `~/clouds/iCloudReplica` symlinks to `~/Library/Mobile Documents`.

Remote ids are stable; update display labels only when they change. Keep `RCLONE_CONFIG_PASS` non-interactive after secrets, validate with root-level `rclone lsd /`, and converge paths without duplicate mounts or directories. Finder favorites never use NSKeyedArchiver, JXA, or `sfltool`; ensure canonical directories then set the exact ordered list with URI-encoded `mysides` in activation, restart Finder, sharedfilelistd, and cfprefsd, and log a logout hint when stale.

Expect 5-15 minutes for full-root incremental sync; runtime paths use no throttle flags. Platform exceptions need `# WHY:`, and non-automatable behavior gets a `MANUAL.md` step in the same change. Details: `src/users/default/agents/skills/nucleus-platform-reference/references/cloud-drives-and-finder.md`.
