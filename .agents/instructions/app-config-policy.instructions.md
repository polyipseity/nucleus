---
description: "Use when adding or editing configs in src/modules/configs/ or application settings."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix"
---

# Application config policy

Method priority for `src/modules/configs/`: 1 writable symlink (default), 2 read-only deployment, 3 selective merge, 4 runtime direct read. Deviations require `# check-suppress:config-method: method N (name) -- <technical reason>`; preference is not a technical reason.

Method 1 uses `seed-writable-symlink.sh` on POSIX and `Deploy-WritableSymlink` with `$env:NUCLEUS_REPO_ROOT` on Windows; never `mkOutOfStoreSymlink` with a `repoRoot`-derived path. `managedSymlinkPaths` owns hardening. Method 2 is for apps that overwrite config or platforms blocking symlinks. Method 3 merges managed subsets key-wise for JSON and section-wise for INI. Method 4 is for nucleus-owned scripts reading `$NUCLEUS_REPO_ROOT`.

Host-specific `lib/` directories hold auto-loaded overrides. Per-user overrides follow `src/users/<username>/<config>/` with merge order `defaults // platform_overrides // user_overrides`. Store the app's native format, implement on every host with the app, and cover enabled hosts with tests.

Details: `src/users/default/agents/skills/nucleus-platform-reference/references/app-config-policy.md`.
