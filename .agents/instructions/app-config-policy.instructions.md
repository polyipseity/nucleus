---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Covers config methods, storage selection, per-user overrides, cross-platform parity, and testing."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix"
---

# Application config policy

Method priority for `src/modules/configs/`. Method 1 is the default; any deviation needs `# check-suppress:config-method: method N (name) -- <technical reason>`, and preference is not a technical reason.

## Method 1: bidirectional writable symlink

Symlink the app config path into the repo tree. POSIX: `seed-writable-symlink.sh` (`entryAfter [ "linkGeneration" ]`, re-anchored via `derive_repo_root`). Windows: `New-Item -ItemType SymbolicLink` to `$env:NUCLEUS_REPO_ROOT`, via `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

Never use `mkOutOfStoreSymlink` with a `repoRoot`-derived path: `repoRoot = ../.` copies into read-only `/nix/store/*-source`, so writes fail `EACCES`. See `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

Writable-vs-immutable is owned by `managedSymlinkPaths` in `src/modules/home.nix`: `writable = true` stays unhardened, everything else is re-hardened by `protect-out-of-store-symlinks`. The helper takes no writable flag and never calls protect/unprotect.

Applies when the app tolerates a symlink without overwriting it with generated state. An app that auto-writes needs the key committed, auto-write disabled, or Method 2/3.

## Method 2: read-only deployment

Nix `xdg.configFile` (POSIX), `Copy-Item` + `ReadOnly` (Windows). Only when the app overwrites the config with generated state, or the platform blocks symlinks (macOS LaunchServices refuses them for `.app` bundles). Invalid for a system-level path or "no user writes it".

## Method 3: selective merge

Managed subset in the repo, merged into the live config at activation, key-wise for JSON and section-wise for INI. Use when the app keeps its own state in the same file (Obsidian `obsidian.json`, Picard `Picard.ini`).

## Method 4: runtime direct read

Nucleus-owned scripts only, reading config through `$NUCLEUS_REPO_ROOT`.

## Host-specific lib/ subdirectory

`src/modules/configs/<name>/lib/` holds overrides the application auto-loads (direnv `lib/*.sh`). Base config stays valid on all hosts; an override deploys only where it applies, documented in the lib header and the deployment module. Example: `src/users/default/direnv/lib/apple-sdk-override.sh`, a macOS `_nix()` override, POSIX deployment via `shell/default.nix`; Windows deploys only base `direnvrc`.

## Per-user overrides

`src/users/<username>/<config>/` over `src/users/default/<config>/`, see `user-config-placement.instructions.md`. Merge order `defaults // platform_overrides // user_overrides`, override fields declared in the user registry (`src/users/<username>/<domain>.json`), merge implemented in the target platform's activation code (`users-registry.nix`, `Load-UserRegistry.ps1`). Method 1 still applies under `src/users/`.

## Storage, parity, tests

Store the format the app reads: JSON when it reads JSON, its native format otherwise.

Implement on every host that has the app, with a `# WHY:` for single-host apps (`cross-host-feature-parity.instructions.md`). Cover enabled hosts with tests and run `nix flake check`.
