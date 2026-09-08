---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Covers config methods, storage selection, per-user overrides, cross-platform parity, and testing."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

# Application config policy

All configs in `src/modules/configs/` follow this method priority:

### Method 1 — Bidirectional writable symlink (default)

Symlink from app config path into repo tree. Edits reflect immediately; no reactivation needed.

**POSIX:** `src/scripts/configs/seed-writable-symlink.sh` from `home.activation` (`entryAfter [ "linkGeneration" ]`), re-anchored to live root via `derive_repo_root`. **Windows:** `New-Item -ItemType SymbolicLink` targeting `$env:NUCLEUS_REPO_ROOT`. See `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

> **Never use `mkOutOfStoreSymlink` with a `repoRoot`-derived path.** `repoRoot = ../.` copies into read-only `/nix/store/*-source` — writes fail `EACCES`. Reference: `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

Writable-vs-immutable owned by `managedSymlinkPaths` (`src/modules/home.nix`): `writable = true` stays unhardened; others re-hardened by `protect-out-of-store-symlinks`. Helper must NOT take a writable flag or call protect/unprotect.

**Use when** app tolerates a symlink without overwriting it with auto-generated state. Apps that auto-write (e.g. `redhat.vscode-yaml`) need the key committed, auto-write disabled, or Method 2/3.

### Method 2 — Read-only deployment (alternative)

Read-only copy at app config path. Nix `xdg.configFile` (POSIX); `Copy-Item` + `ReadOnly` (Windows).

**Use when:** app overwrites config with auto-generated state, or platform limitation (e.g. macOS LaunchServices refuses symlinks for .app bundles). **Not valid:** system-level path (use writable symlink), "no user writes it" (Method 1 is correct), or "immutability preference."

### Method 3 — Selective merge (alternative)

Managed subset stored in repo, merged into live config at activation. Key-wise (JSON) or section-wise (INI); app-owned data preserved.

**Use when** app manages its own state in the same file (e.g. Obsidian `obsidian.json`, Picard `Picard.ini`).

### Method 4 — Runtime direct read (nucleus infrastructure only)

Script reads config directly via `$NUCLEUS_REPO_ROOT`. For nucleus-owned scripts only.

### Priority rule

1. Method 1 by default. Method 2 only with documented technical constraint making Method 1 impossible.
2. Method 2 if 1 unsuitable. Method 3 if 2 unsuitable. Method 4 for nucleus-owned infrastructure only.
3. Deviation from Method 1 requires `# check-suppress:config-method: method N (name) -- <reason>`.
4. Equivalent deployment on all applicable hosts. Document N/A for hosts without the application.

### Host-specific lib/ subdirectory convention

`src/modules/configs/<name>/lib/` holds host-specific overrides auto-loaded by the application (e.g. direnv `lib/*.sh`). Platform-specific; deploying to other hosts is dead code. Rules: base config valid on all hosts; overrides deploy only on needed hosts; document in lib file header and deployment module comment; N/A for hosts without the app.

Example: `src/users/default/direnv/lib/apple-sdk-override.sh` — macOS `_nix()` override, deployed on POSIX via `shell.nix`; Windows deploys only base `direnvrc`.

### User-scoped configs

Per-user configs in `src/users/<username>/<config>/` with `src/users/default/<config>/` as template. See `user-config-placement.instructions.md`. Selection: `mkUserOverlay` (POSIX), `Resolve-UserConfig*` (Windows). Registry domains use `users-registry.nix`. Outside step-19 scan — no `# check-suppress:config-method` needed for `src/users/**`, but method-1 rule applies.

## Management workflow

### Storage location

**JSON file** if app reads JSON directly. **Native format** if app does not read JSON — store in the format app reads.

### Per-user override pattern

Merge order: `defaults // platform_overrides // user_overrides`. Define override fields in user registry (`src/users/<username>/<domain>.json`). Nix: `users-registry.nix`; Windows: `Load-UserRegistry.ps1`. Implement merge in target platform's activation code. Add tests.

### Cross-platform parity

Audit all three hosts. For each with the app: defaults centrally defined, override fields in registry, merge order applied, tests cover enabled hosts. Single-host apps need `# WHY:`. See `cross-host-feature-parity.instructions.md`.

### Checklist

- Storage: JSON or native format. Add defaults, override fields, merge logic.
- Activate on all platforms or document exceptions with `# WHY:`.
- Add tests; verify `nix flake check` and all tests pass.
- Verify `# check-suppress:config-method: method N` cites technical reason, not preference.
