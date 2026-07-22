---
description: "Use when adding or editing configs in src/modules/configs/. Mandates uniform config application methods with priority ordering and cross-platform parity."
name: "Application Config Policy"
applyTo: "src/modules/configs/**"
---

## Config application policy

All configs in `src/modules/configs/` must follow this method priority, chosen by the nature of the target application's config behavior:

### Method 1 — Bidirectional writable symlink (default)

A symlink from the app's config path back into the repo tree. Edits through the symlink (by user or app) are immediately reflected in the repo; repo changes are visible without reactivation. This is the default because it makes edits take effect immediately without a rebuild/reactivation cycle — the lightest-weight abstraction.

**Implementation:** Nix `mkOutOfStoreSymlink` (POSIX); PowerShell `New-Item -ItemType SymbolicLink` (Windows).

**Use when:** The app tolerates a symlink at its config path and does not overwrite it with auto-generated state on startup.

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
5. Any deviation from Method 1 must have a code comment citing the specific technical reason why Method 1 is unsuitable (e.g., "app overwrites this file on startup — using merge instead of symlink to preserve managed settings"). "No user writes it", "system-level path", and "read-only by convention" are not valid reasons.
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

Example: `src/modules/configs/direnv/lib/apple-sdk-override.sh` — a macOS-specific `_nix()` override auto-sourced by direnv. Deployed on POSIX hosts via the shared `shell.nix`; Windows deploys only the base `direnvrc`.
