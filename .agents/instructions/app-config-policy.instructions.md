---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Covers config application methods, storage location selection, per-user override patterns, cross-platform parity, and testing requirements."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

# Application config policy

## Config application policy

All configs in `src/modules/configs/` must follow this method priority, chosen by the target application's config behavior:

### Method 1 — Bidirectional writable symlink (default)

A symlink from the app's config path back into the repo tree. Edits through the symlink are immediately reflected in the repo; repo changes are visible without reactivation.

**Implementation (POSIX):** create the symlink at activation time against the live repo root via `derive_repo_root` (`$NUCLEUS_REPO_ROOT`), using `src/scripts/configs/seed-writable-symlink.sh` invoked from a `home.activation` entry (`entryAfter [ "linkGeneration" ]`). The repo-relative source path is computed at eval time (a literal string, or `overlay.toRepoRelPath (overlay.selectFile ...)` for per-user configs) and re-anchored to the live root by the helper.

> **Do NOT use `mkOutOfStoreSymlink` with a `repoRoot`-derived path for method-1 links.** `flake.nix` defines `repoRoot = ../.` as a Nix path literal, which Nix copies into a read-only `/nix/store/*-source` snapshot at eval time. `config.lib.file.mkOutOfStoreSymlink "${repoRoot}/..."` points at that read-only store path, not the live working tree. Writes fail with `EACCES` (e.g. camillagui-backend returns HTTP 500). Use `seed-writable-symlink.sh` instead. Reference: `src/platforms/macOS/scripts/macos-configure-linearmouse.sh`.

**Implementation (Windows):** `New-Item -ItemType SymbolicLink` with `-Target` at the live repo root (`$env:NUCLEUS_REPO_ROOT`, or `$repoRoot` from `$PSScriptRoot`). See `Deploy-WritableSymlink` in `ConfigHelpers.ps1`.

**Writable-vs-immutable** is owned by `managedSymlinkPaths` (`src/modules/home.nix`): `writable = true` entries stay unhardened; others are re-hardened immutable by the `protect-out-of-store-symlinks` activation. The symlink-creation helper must NOT take a writable flag or call protect/unprotect — that duplicates `managedSymlinkPaths` and risks divergence.

**Use when:** the app tolerates a symlink without overwriting it with auto-generated state. Some apps auto-write state into config (e.g. `redhat.vscode-yaml` writes `yaml.disableSchemaDetection` into VS Code `settings.json`). Resolve by committing the key, disabling the auto-write, or switching to Method 2/3.

### Method 2 — Read-only deployment (alternative)

A read-only copy (Nix store path or file with ReadOnly attribute) at the app's config path. Changes require editing the repo file and reactivating.

**Implementation:** Nix `xdg.configFile` (POSIX); `Copy-Item` + `ReadOnly` (Windows).

**Use when:**

- The app overwrites the config file with auto-generated state on startup.
- A platform limitation requires a read-only copy (e.g., macOS LaunchServices refuses symlinks for .app bundles).

**Not valid reasons for Method 2:**

- System-level path (`/etc/`, `/etc/ssh/`) — use an activation script for a writable symlink instead.
- "No user writes it" or "read-only by convention" — if the app tolerates a symlink, Method 1 is correct.
- Preference for immutability — Method 2 is a technical alternative, not a stylistic choice.

### Method 3 — Selective merge (alternative)

The managed subset is stored in the repo and merged into the live config at activation time. Key-wise (JSON) or section-wise (INI); app-owned data outside managed keys is preserved.

**Implementation:** activation-block shell script (awk/Python) merging repo file into live path (POSIX); equivalent PowerShell merge (Windows).

**Use when** the app manages its own state in the same file (e.g., vault metadata in Obsidian `obsidian.json`, user preferences in Picard `Picard.ini`). A symlink would let the app write its full state back into the repo.

### Method 4 — Runtime direct read (nucleus infrastructure only)

No deployment. The script reads the config directly from the repo tree via `$NUCLEUS_REPO_ROOT`.

**Use when** config is consumed only by nucleus-owned scripts.

### Priority rule

1. Method 1 by default. Method 2 only with a documented technical constraint that makes Method 1 impossible.
2. If Method 1 is unsuitable, use Method 2. If Method 2 is unsuitable, use Method 3.
3. Method 4 is for nucleus-owned infrastructure configs only.
4. Deviation from Method 1 requires a code comment citing the technical reason: `# check-suppress:config-method: method N (name) -- <reason>`. See Method 2 for invalid reasons.
5. Every config must have equivalent deployment on all applicable hosts (macOS, NixOS, Windows). Document N/A for hosts without the application.

### Host-specific lib/ subdirectory convention

Configs under `src/modules/configs/<name>/` may contain a `lib/` subdirectory for host-specific override scripts that the target application auto-loads. Applies when:

- The application has a native extension-point mechanism (e.g., direnv's `~/.config/direnv/lib/*.sh` auto-sourcing).
- The override content is platform-specific and deploying it to other hosts would be dead code.

Rules:

1. The base config file must contain content valid on all hosts where deployed.
2. Host-specific overrides in `lib/` deploy only on needed hosts. Harmless overrides may deploy via a shared module with a rationale comment.
3. Document the convention in the lib file's header comment and the deployment module's comment block.
4. If a host does not deploy the application, document as N/A per cross-host parity policy.

Example: `src/users/default/direnv/lib/apple-sdk-override.sh` — a macOS-specific `_nix()` override auto-sourced by direnv. Deployed on POSIX via `shell.nix`; Windows deploys only the base `direnvrc`.

### User-scoped configs

Per-user homedir configs live in `src/users/<username>/<config>/` with `src/users/default/<config>/` as default. See `user-config-placement.instructions.md` for placement and overlay coverage. Selection goes through `mkUserOverlay` in `src/modules/lib/users-overlay.nix` (POSIX), `Resolve-UserConfig*` / `Deploy-UserWritableSymlink` in `ConfigHelpers.ps1` (Windows), and `resolve-user-config.sh` (POSIX activation). Registry JSON domains use `users-registry.nix`. These paths are outside the step-19 config-method-compliance scan (`src/modules/configs/**` only) — no `# check-suppress:config-method` annotations required for `src/users/**` sites, but the same method-1 writable-symlink rule applies.

## Management workflow

### Storage location rule

Choose app config storage based on how the app reads it, not on arbitrary preference.

#### Separate JSON file (app reads JSON directly)

Use a separate JSON file under `src/modules/configs/<app>/` only if the app reads that file directly. Symlink from activation code (macOS: `src/platforms/macOS/modules/default.nix`; Windows: DSC or modules).

#### Native config format (app does NOT read JSON)

Store in the format the app actually reads (Nix attrset rendered to INI, defaults domain, or registry). Do not create a JSON file the app will ignore.

### Per-user override pattern

All app settings must support per-user overrides. Merge order: `defaults // platform_overrides // user_overrides`.

1. Define override fields in the user registry (`src/users/<username>/<domain>.json`, with `src/users/default/` as template). Nix modules consume via `src/modules/lib/users-registry.nix`; Windows scripts use `Load-UserRegistry.ps1`.
2. Implement merge logic in the target platform's activation code.
3. Add tests asserting override fields exist and are wired correctly.

### Cross-platform parity

When adding app settings, audit all three hosts (macOS, NixOS, Windows). For each host where the app exists: ensure defaults are centrally defined, user override fields exist in the registry, activation applies `defaults // platform_overrides // user_overrides` in order, and tests cover all enabled hosts. Single-host apps need a `# WHY:` comment. See `cross-host-feature-parity.instructions.md`.

### Checklist for adding a new app config

- Determine storage location: separate JSON (if app reads it) or native format.
- Add defaults in the appropriate location.
- Add user override fields to user registries.
- Implement merge logic.
- Activate on all applicable platforms or document exceptions with `# WHY:`.
- Add tests.
- Verify `nix flake check` and all tests pass.
- Verify `# check-suppress:config-method: method N` cites a technical reason, not a preference.
