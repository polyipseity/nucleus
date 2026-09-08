---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Covers config methods, storage selection, per-user overrides, cross-platform parity, and testing."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

# Application config policy

All configs in `src/modules/configs/` follow this method priority:

### Method 1 — Bidirectional writable symlink (default)

Symlink from the app's config path into the repo tree. Edits reflect immediately; no reactivation needed.

**POSIX:** symlink at activation time via `derive_repo_root` (`$NUCLEUS_REPO_ROOT`), using `src/scripts/configs/seed-writable-symlink.sh` from a `home.activation` entry (`entryAfter [ "linkGeneration" ]`). Source path computed at eval time, re-anchored to live root by the helper.

> **Never use `mkOutOfStoreSymlink` with a `repoRoot`-derived path.** `repoRoot = ../.` is a Nix path literal copied into read-only `/nix/store/*-source` at eval time — writes fail with `EACCES` (e.g. camillagui-backend HTTP 500). Use `seed-writable-symlink.sh`. Reference: `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

**Windows:** `New-Item -ItemType SymbolicLink` targeting live repo root (`$env:NUCLEUS_REPO_ROOT`). See `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

**Writable-vs-immutable** is owned by `managedSymlinkPaths` (`src/modules/home.nix`): `writable = true` stays unhardened; others re-hardened immutable by `protect-out-of-store-symlinks`. The helper must NOT take a writable flag or call protect/unprotect — that duplicates `managedSymlinkPaths` and risks divergence.

**Use when:** the app tolerates a symlink without overwriting it with auto-generated state. Some apps auto-write state (e.g. `redhat.vscode-yaml` writes `yaml.disableSchemaDetection` into VS Code `settings.json`). Resolve by committing the key, disabling the auto-write, or switching to Method 2/3.

### Method 2 — Read-only deployment (alternative)

Read-only copy at the app's config path. Changes require editing the repo file and reactivating.

**Implementation:** Nix `xdg.configFile` (POSIX); `Copy-Item` + `ReadOnly` (Windows).

**Use when:**

- The app overwrites config with auto-generated state on startup.
- Platform limitation requires a read-only copy (e.g. macOS LaunchServices refuses symlinks for .app bundles).

**Not valid reasons:** system-level path (`/etc/`) — use activation script for writable symlink; "no user writes it" — if app tolerates a symlink, Method 1 is correct; "preference for immutability" — technical alternative, not stylistic.

### Method 3 — Selective merge (alternative)

Managed subset stored in repo, merged into live config at activation time. Key-wise (JSON) or section-wise (INI); app-owned data preserved.

**Implementation:** activation-block shell script merging repo file into live path (POSIX); equivalent PowerShell merge (Windows).

**Use when** the app manages its own state in the same file (e.g. vault metadata in Obsidian `obsidian.json`, preferences in Picard `Picard.ini`). A symlink would let the app write full state back.

### Method 4 — Runtime direct read (nucleus infrastructure only)

No deployment. Script reads config directly from the repo tree via `$NUCLEUS_REPO_ROOT`. For nucleus-owned scripts only.

### Priority rule

1. Method 1 by default. Method 2 only with documented technical constraint making Method 1 impossible.
2. Method 2 if Method 1 unsuitable. Method 3 if Method 2 unsuitable.
3. Method 4 for nucleus-owned infrastructure only.
4. Deviation from Method 1 requires: `# check-suppress:config-method: method N (name) -- <reason>` with a technical reason (see Method 2 for invalid reasons).
5. Every config must have equivalent deployment on all applicable hosts (macOS, NixOS, Windows). Document N/A if host lacks the application.

### Host-specific lib/ subdirectory convention

Configs under `src/modules/configs/<name>/` may contain `lib/` for host-specific override scripts auto-loaded by the target application. Applies when the app has a native extension-point (e.g. direnv `lib/*.sh`) and the override is platform-specific.

Rules:

1. Base config must be valid on all hosts where deployed.
2. Host-specific overrides deploy only on needed hosts. Harmless overrides may deploy via shared module with rationale comment.
3. Document the convention in the lib file header and deployment module comment block.
4. If a host does not deploy the application, document as N/A.

Example: `src/users/default/direnv/lib/apple-sdk-override.sh` — macOS-specific `_nix()` override. Deployed on POSIX via `shell.nix`; Windows deploys only base `direnvrc`.

### User-scoped configs

Per-user homedir configs in `src/users/<username>/<config>/` with `src/users/default/<config>/` as template. See `user-config-placement.instructions.md`. Selection via `mkUserOverlay` (POSIX), `Resolve-UserConfig*` / `Deploy-UserWritableSymlink` (Windows), `resolve-user-config.sh` (POSIX activation). Registry domains use `users-registry.nix`. Outside step-19 config-method-compliance scan — no `# check-suppress:config-method` needed for `src/users/**`, but method-1 writable-symlink rule still applies.

## Management workflow

### Storage location rule

Choose based on how the app reads config, not preference.

#### Separate JSON (app reads JSON directly)

Separate JSON under `src/modules/configs/<app>/` only if the app reads that file directly. Symlink from activation code.

#### Native config format (app does NOT read JSON)

Store in the format the app reads (Nix attrset → INI, defaults domain, registry). Do not create a JSON file the app ignores.

### Per-user override pattern

All settings must support per-user overrides. Merge order: `defaults // platform_overrides // user_overrides`.

1. Define override fields in user registry (`src/users/<username>/<domain>.json`, default in `src/users/default/`). Nix modules consume via `users-registry.nix`; Windows via `Load-UserRegistry.ps1`.
2. Implement merge logic in the target platform's activation code.
3. Add tests asserting override fields exist and are wired correctly.

### Cross-platform parity

Audit all three hosts when adding settings. For each host with the app: defaults centrally defined, override fields in registry, activation applies merge order, tests cover all enabled hosts. Single-host apps need `# WHY:` comment. See `cross-host-feature-parity.instructions.md`.

### Checklist for adding a new app config

- Determine storage location: separate JSON or native format.
- Add defaults, user override fields, and merge logic.
- Activate on all applicable platforms or document exceptions with `# WHY:`.
- Add tests; verify `nix flake check` and all tests pass.
- Verify `# check-suppress:config-method: method N` cites a technical reason, not a preference.
