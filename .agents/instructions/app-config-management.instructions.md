---
description: "Use when adding or modifying application settings and configurations. Covers storage location selection, per-user override patterns, cross-platform parity, and testing requirements."
name: "App Configuration Management"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/modules/configs/**, src/hosts/Windows/modules/**/*.ps1, src/flake.nix, src/users/**/*.json, tests/modules/*-tests.nix, tests/integration/*-tests.nix, tests/hosts/**/*-tests.nix"
---

## Storage location rule

Choose app config storage based on how the app reads it, not on arbitrary preference.

### Separate JSON file (app reads JSON directly)

Use a separate JSON file under `src/modules/configs/<app>/` only if the app reads that file directly. Symlink the file to the app's config path from activation code (macOS: `src/modules/macos.nix`; Windows: DSC or modules).

### Native config format (app does NOT read JSON)

Store settings in the format the app actually reads (e.g., Nix attrset rendered to INI, defaults domain, or registry). Do not create a JSON file the app will ignore.

## Per-user override pattern

All app settings must support per-user overrides. The merge order is: `defaults // platform_overrides // user_overrides`.

1. Define override fields in the user registry (`src/users/<username>/<domain>.json`, with `src/users/default/` fallback). Nix modules consume the assembled registry via `src/modules/lib/users-registry.nix`; Windows scripts use `Load-UserRegistry.ps1`.
2. Implement merge logic in the target platform's activation code.
3. Add tests asserting override fields exist and are wired correctly.

## Cross-platform parity

When adding app settings, audit all three hosts (macOS, NixOS, Windows). For each host where the app exists, ensure defaults are centrally defined, user override fields exist in the user registry, activation applies `defaults // platform_overrides // user_overrides` in the same order, and tests cover all enabled hosts. If an app exists on only one or two hosts, document why with a `# WHY:` comment in code. See `cross-host-feature-parity.instructions.md` for the full parity policy.

## Checklist for adding a new app config

- Determine storage location: separate JSON (if app reads it) or native format.
- Add defaults in the appropriate location.
- Add user override fields to user registries.
- Implement merge logic.
- Activate on all applicable platforms or document exceptions with `# WHY:`.
- Add tests.
- Verify `nix flake check` and all tests pass.
- After choosing a config method, verify the `# check-suppress:config-method: method N` comment cites a technical reason, not a preference (see `app-config-policy.instructions.md` Method 2 for invalid justifications).
