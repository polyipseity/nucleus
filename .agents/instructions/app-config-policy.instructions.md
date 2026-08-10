---
description: "Use when adding or editing configs in src/modules/configs/ or modifying application settings. Mandates uniform config application methods with priority ordering, storage location selection, per-user override patterns, cross-platform parity, and testing requirements."
name: "Application Config Policy"
applyTo: "src/modules/configs/**, src/modules/**/*.nix, src/hosts/**/*.nix, src/platforms/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

## Config application policy

All configs in `src/modules/configs/` must follow this method priority, chosen by the nature of the target application's config behavior:

### Method 1 — Bidirectional writable symlink (default)

A symlink from the app's config path back into the repo tree. Edits through the symlink (by user or app) are immediately reflected in the repo; repo changes are visible without reactivation. This is the default because it makes edits take effect immediately without a rebuild/reactivation cycle — the lightest-weight abstraction.

**Implementation:** Nix `mkOutOfStoreSymlink` (POSIX); PowerShell `New-Item -ItemType SymbolicLink` (Windows).

**Use when:** The app tolerates a symlink at its config path and does not overwrite it with auto-generated state on startup.

Some apps auto-write managed state into their config at startup or on activation (e.g. `redhat.vscode-yaml` writes `yaml.disableSchemaDetection` into VS Code user `settings.json`). With a writable symlink, every auto-write re-dirties the repo working tree. Resolve by committing the auto-written key intentionally, disabling the auto-write, or switching to Method 2/3.

### Method 2 — Read-only deployment (fallback)

A read-only copy (Nix store path or copied file with ReadOnly attribute) at the app's config path. Changes require editing the repo file and reactivating.

**Implementation:** Nix `xdg.configFile` (POSIX); PowerShell `Copy-Item` + `ReadOnly` (Windows).

**Use when:**

- The app overwrites the config file with auto-generated state on startup (e.g., serializing full internal state, discarding managed settings).
- A platform limitation requires a read-only copy (e.g., macOS LaunchServices refuses symlinks for .app bundles).

**NOT valid reasons for Method 2:**

- The config path is system-level (`/etc/`, `/etc/ssh/`, etc.) — system paths do not inherently require read-only deployment. Use an activation script to create a writable symlink instead.
- "No user writes it" or "read-only by convention" — if the app tolerates a symlink without overwriting it, Method 1 is the correct choice.
- Preference for immutability — Method 2 is a technical fallback, not a stylistic choice.

### Method 3 — Selective merge (fallback)

The managed subset is stored in the repo and merged into the live app config at activation time. Merge is key-wise (JSON) or section-wise (INI); app-owned data outside managed keys is preserved.

**Implementation:** activation-block shell script (awk/Python) reading repo file and merging into live path (POSIX); equivalent PowerShell merge (Windows).

**Use when:** The app manages its own state in the same file (e.g., vault metadata in Obsidian `obsidian.json`, user preferences in Picard `Picard.ini`). A symlink would let the app write its full state back into the repo file.

### Method 4 — Runtime direct read (nucleus infrastructure only)

No deployment. The script reads the config directly from the repo tree at runtime via `$NUCLEUS_REPO_ROOT`.

**Use when:** Config is consumed only by nucleus-owned scripts, never by third-party apps.

### Priority rule

1. Always use Method 1. Method 2 is only acceptable with a documented technical constraint that makes Method 1 impossible.
2. If Method 1 is unsuitable, use Method 2.
3. If Method 2 is unsuitable, use Method 3.
4. Method 4 is for nucleus-owned infrastructure configs only.
5. Any deviation from Method 1 must have a code comment citing the specific technical reason why Method 1 is unsuitable, using the canonical annotation format `# check-suppress:config-method: method N (name) -- <reason>` (e.g., "app overwrites this file on startup -- using merge instead of symlink to preserve managed settings"). See Method 2 for invalid reasons.
6. Every config must have equivalent deployment on all applicable hosts (macOS, NixOS, Windows). If a host has no equivalent application, document as N/A.

### Host-specific lib/ subdirectory convention

Configs under `src/modules/configs/<name>/` may contain a `lib/` subdirectory for host-specific override scripts that the target application auto-loads. This applies when:

- The application has a native extension-point mechanism (e.g., direnv's `~/.config/direnv/lib/*.sh` auto-sourcing) designed for reusable override modules.
- The override content is platform-specific (macOS apple-sdk vars, Linux-specific hardening, etc.) and deploying it to other hosts would be dead code.

Rules:

1. The base config file at `src/modules/configs/<name>/<config-file>` must contain content valid on all hosts where the file is deployed.
2. Host-specific override scripts in `lib/` are deployed only on the hosts where they are needed. If the override is harmless on other platforms, it MAY be deployed via a shared module with a comment noting the rationale.
3. The convention MUST be documented in the lib file's header comment and in the deployment module's comment block.
4. When a host does not deploy the application at all (e.g., no direnv on a host), document as N/A per the cross-host parity policy.

Example: `src/users/default/direnv/lib/apple-sdk-override.sh` — a macOS-specific `_nix()` override auto-sourced by direnv. Deployed on POSIX hosts via the shared `shell.nix`; Windows deploys only the base `direnvrc`.

### User-scoped configs

Per-user homedir configs live in `src/users/<username>/<config>/` with `src/users/default/<config>/` as defaults-fallback. Placement rules and overlay coverage requirements are in `user-config-placement.instructions.md`. File selection goes through `mkUserOverlay` in `src/modules/lib/users-overlay.nix` (POSIX), `Resolve-UserConfig*` / `Deploy-UserWritableSymlink` in `ConfigHelpers.ps1` (Windows), and `resolve-user-config.sh` (POSIX activation scripts). Registry JSON domains use `users-registry.nix` instead. These paths are OUTSIDE the step-19 config-method-compliance scan (`src/modules/configs/**` only) — no `# check-suppress:config-method` annotations are required for `src/users/**` reference sites, but the same method-1 writable-symlink rule still applies.

## Management workflow

### Storage location rule

Choose app config storage based on how the app reads it, not on arbitrary preference.

#### Separate JSON file (app reads JSON directly)

Use a separate JSON file under `src/modules/configs/<app>/` only if the app reads that file directly. Symlink the file to the app's config path from activation code (macOS: `src/platforms/macOS/modules/default.nix`; Windows: DSC or modules).

#### Native config format (app does NOT read JSON)

Store settings in the format the app actually reads (e.g., Nix attrset rendered to INI, defaults domain, or registry). Do not create a JSON file the app will ignore.

### Per-user override pattern

All app settings must support per-user overrides. The merge order is: `defaults // platform_overrides // user_overrides`.

1. Define override fields in the user registry (`src/users/<username>/<domain>.json`, with `src/users/default/` fallback). Nix modules consume the assembled registry via `src/modules/lib/users-registry.nix`; Windows scripts use `Load-UserRegistry.ps1`.
2. Implement merge logic in the target platform's activation code.
3. Add tests asserting override fields exist and are wired correctly.

### Cross-platform parity

When adding app settings, audit all three hosts (macOS, NixOS, Windows). For each host where the app exists, ensure defaults are centrally defined, user override fields exist in the user registry, activation applies `defaults // platform_overrides // user_overrides` in the same order, and tests cover all enabled hosts. If an app exists on only one or two hosts, document why with a `# WHY:` comment in code. See `cross-host-feature-parity.instructions.md` for the full parity policy.

### Checklist for adding a new app config

- Determine storage location: separate JSON (if app reads it) or native format.
- Add defaults in the appropriate location.
- Add user override fields to user registries.
- Implement merge logic.
- Activate on all applicable platforms or document exceptions with `# WHY:`.
- Add tests.
- Verify `nix flake check` and all tests pass.
- After choosing a config method, verify the `# check-suppress:config-method: method N` comment cites a technical reason, not a preference (see Method 2 above for invalid justifications).
