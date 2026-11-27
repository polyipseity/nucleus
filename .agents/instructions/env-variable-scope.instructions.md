---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

Every env var is all-process by default; narrower scope needs inline `# WHY:`. The `catalog` in `src/modules/lib/env-secrets.nix` holds per-host `values`, `why`, and optional `userSpecific`; PATH lives in `src/modules/lib/managed-paths.nix` with separate `prepend` and `append` lists. Windows applies non-user-specific entries at Machine scope and user-specific ones at User scope; elevation failure is a hard error.

Host-keyed entries resolve to null elsewhere; consumers guard instead of substituting defaults. Delivery must cover POSIX shells, macOS GUI processes through `gui-env`, and PowerShell through `init.ps1` or `Sync-ShellProfile.ps1`. Toolchain values use stable SYSTEM root symlinks, never raw `/nix/store` paths. `RIP_GRAVEYARD` is userSpecific and its directory is created by activation, not by the variable alone.

Valid narrow scopes are incorrect behavior for unintended consumers, platform-specific values, and build-time infeasibility. `"CLI-only"` is invalid on NixOS and Windows. Parity tests are `tests/integration/env-parity-tests.nix` and `tests/platforms/Windows/modules/EnvVarParity.Tests.ps1`; a new variable needs both.

Exception table and path details: `.agents/skills/nucleus-platform-reference/references/env-variable-scope.md`.
