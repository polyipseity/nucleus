---
description: "Use when adding or editing configs in src/modules/configs/ or application settings."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix"
---

# Application config policy

Method priority for `src/modules/configs/`. Method 1 is the default; deviations need `# check-suppress:config-method: method N (name) -- <technical reason>`. Preference is not a technical reason.

## Method 1: writable symlink

Symlink the app config path into the repo tree. POSIX uses `seed-writable-symlink.sh` (`entryAfter [ "linkGeneration" ]`, re-anchored with `derive_repo_root`); Windows uses `New-Item -ItemType SymbolicLink` to `$env:NUCLEUS_REPO_ROOT` through `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

Never use `mkOutOfStoreSymlink` with a `repoRoot`-derived path: `repoRoot = ../.` copies into read-only `/nix/store/*-source`, so writes fail `EACCES`. See `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

`managedSymlinkPaths` in `src/modules/home.nix` owns writability: `writable = true` stays unhardened, the rest is re-hardened by `protectOutOfStoreSymlinks`. The helper takes no writable flag and never calls protect or unprotect. Use this method when the app tolerates a symlink and does not overwrite it with generated state; otherwise disable auto-write or use Method 2 or 3.

## Method 2: read-only deployment

Nix `xdg.configFile` on POSIX, `Copy-Item` plus `ReadOnly` on Windows. Only when the app overwrites the config with generated state or the platform blocks symlinks (macOS LaunchServices refuses them for `.app` bundles). Invalid for a system-level path or "no user writes it".

## Method 3: selective merge

Managed subset in the repo, merged into the live config at activation, key-wise for JSON and section-wise for INI. Use when the app keeps its own state in the same file (Obsidian `obsidian.json`, Picard `Picard.ini`).

## Method 4: runtime direct read

Nucleus-owned scripts only, reading config through `$NUCLEUS_REPO_ROOT`.

## Host-specific lib/

`src/modules/configs/<name>/lib/` holds overrides an app auto-loads (direnv `lib/*.sh`). The base config stays valid on all hosts; an override deploys only where it applies, documented in the lib header and deployment module. Example: `src/users/default/direnv/lib/apple-sdk-override.sh`, a macOS `_nix()` override deployed by `shell/default.nix`; Windows gets only base `direnvrc`.

## Per-user overrides

`src/users/<username>/<config>/` over `src/users/default/<config>/`, per `user-config-placement.instructions.md`. Merge order `defaults // platform_overrides // user_overrides`; override fields declared in the user registry (`src/users/<username>/<domain>.json`) and merged in platform activation (`users-registry.nix`, `Load-UserRegistry.ps1`). Method 1 still applies under `src/users/`.

## Storage, parity, tests

Store the format the app reads. Implement on every host that has the app, with `# WHY:` for single-host apps (`cross-host-feature-parity.instructions.md`). Cover enabled hosts with tests and run `nix flake check`.
