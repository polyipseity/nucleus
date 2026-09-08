---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Covers config methods, storage selection, per-user overrides, cross-platform parity, and testing."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

# Application config policy

All configs in `src/modules/configs/` follow this method priority:

### Method 1 — Bidirectional writable symlink (default)

Symlink from app config path into repo tree. Edits reflect immediately; no reactivation needed.

**POSIX:** symlink at activation time via `derive_repo_root` using `src/scripts/configs/seed-writable-symlink.sh` from `home.activation` (`entryAfter [ "linkGeneration" ]`). Source path computed at eval time, re-anchored to live root by helper.

> **Never use `mkOutOfStoreSymlink` with a `repoRoot`-derived path.** `repoRoot = ../.` is a Nix path literal — copies into read-only `/nix/store/*-source` at eval. Writes fail `EACCES`. Use `seed-writable-symlink.sh`. Reference: `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

**Windows:** `New-Item -ItemType SymbolicLink` targeting `$env:NUCLEUS_REPO_ROOT`. See `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

**Writable-vs-immutable** owned by `managedSymlinkPaths` (`src/modules/home.nix`): `writable = true` stays unhardened; others re-hardened by `protect-out-of-store-symlinks`. Helper must NOT take a writable flag or call protect/unprotect.

**Use when** app tolerates a symlink without overwriting it with auto-generated state. Apps that auto-write state (e.g. `redhat.vscode-yaml`) need the key committed, auto-write disabled, or Method 2/3.

### Method 2 — Read-only deployment (alternative)

Read-only copy at app config path. Changes require editing repo and reactivating. Nix `xdg.configFile` (POSIX); `Copy-Item` + `ReadOnly` (Windows).

**Use when:** app overwrites config with auto-generated state, or platform limitation (e.g. macOS LaunchServices refuses symlinks for .app bundles).

**Not valid:** system-level path — use activation script for writable symlink; "no user writes it" — if app tolerates symlink, Method 1 is correct; "immutability preference" — technical alternative, not stylistic.

### Method 3 — Selective merge (alternative)

Managed subset stored in repo, merged into live config at activation. Key-wise (JSON) or section-wise (INI); app-owned data preserved. Implementation: activation-block script (awk/Python, POSIX) or PowerShell merge (Windows).

**Use when** app manages its own state in the same file (e.g. Obsidian `obsidian.json` vault metadata, Picard `Picard.ini` preferences).

### Method 4 — Runtime direct read (nucleus infrastructure only)

No deployment. Script reads config directly via `$NUCLEUS_REPO_ROOT`. For nucleus-owned scripts only.

### Priority rule

1. Method 1 by default. Method 2 only with documented technical constraint making Method 1 impossible.
2. Method 2 if 1 unsuitable. Method 3 if 2 unsuitable.
3. Method 4 for nucleus-owned infrastructure only.
4. Deviation from Method 1 requires: `# check-suppress:config-method: method N (name) -- <reason>` with technical reason.
5. Equivalent deployment on all applicable hosts (macOS, NixOS, Windows). Document N/A for hosts without the application.

### Host-specific lib/ subdirectory convention

Configs under `src/modules/configs/<name>/` may contain `lib/` for host-specific override scripts auto-loaded by the application. Applies when the app has a native extension-point (e.g. direnv `lib/*.sh`) and overrides are platform-specific.

1. Base config must be valid on all hosts.
2. Host-specific overrides deploy only on needed hosts.
3. Document convention in lib file header and deployment module comment.
4. Hosts without the application: document as N/A.

Example: `src/users/default/direnv/lib/apple-sdk-override.sh` — macOS `_nix()` override, deployed on POSIX via `shell.nix`; Windows deploys only base `direnvrc`.

### User-scoped configs

Per-user configs in `src/users/<username>/<config>/` with `src/users/default/<config>/` as template. See `user-config-placement.instructions.md`. Selection: `mkUserOverlay` (POSIX), `Resolve-UserConfig*`/`Deploy-UserWritableSymlink` (Windows), `resolve-user-config.sh` (POSIX activation). Registry domains use `users-registry.nix`. Outside step-19 scan — no `# check-suppress:config-method` needed for `src/users/**`, but method-1 rule applies.

## Management workflow

### Storage location

Choose based on how the app reads config. **JSON file** under `src/modules/configs/<app>/` only if app reads JSON directly; symlink from activation. **Native format** if app does not read JSON — store in the format app reads (INI, defaults domain, registry).

### Per-user override pattern

Merge order: `defaults // platform_overrides // user_overrides`.

1. Define override fields in user registry (`src/users/<username>/<domain>.json`). Nix: `users-registry.nix`; Windows: `Load-UserRegistry.ps1`.
2. Implement merge in target platform's activation code.
3. Add tests asserting override fields exist and are wired correctly.

### Cross-platform parity

Audit all three hosts. For each with the app: defaults centrally defined, override fields in registry, activation applies merge order, tests cover all enabled hosts. Single-host apps need `# WHY:`. See `cross-host-feature-parity.instructions.md`.

### Checklist for adding a new app config

- Determine storage: separate JSON or native format.
- Add defaults, override fields, merge logic.
- Activate on all platforms or document exceptions with `# WHY:`.
- Add tests; verify `nix flake check` and all tests pass.
- Verify `# check-suppress:config-method: method N` cites technical reason, not preference.
