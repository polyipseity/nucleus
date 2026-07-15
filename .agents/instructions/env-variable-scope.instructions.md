---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification. See also the cross-host GUI env var propagation plan in the conversation history."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

Every environment variable set by this repo must default to all-process availability on the host. Restricting scope (shell-only, service-only) is an exception requiring an inline `# WHY` comment.

## Centralized registry

All Nix-side env vars are declared in `src/modules/lib/env-vars.nix`. The catalog entries specify value, scope, allowed hosts, and rationale. Platform-specific helper functions (`toHomeSessionVariables`, `toNixOSSystemEnvironment`, `toLaunchctlScript`, `toNixOSServiceEnv`) consume the catalog.

- **Adding a new var**: add an entry to `src/modules/lib/env-vars.nix` catalog, then run the appropriate helper in the target module.
- **Windows parity**: `src/hosts/Windows/user/env.dsc.yml` is the Windows parallel registry.  Parity is enforced by `tests/hosts/Windows/EnvVarParity.Tests.ps1`.  See `docs/env-variable-registry.md` for the cross-reference table.
- **Overriding per host**: use the `override` attr in the catalog entry (e.g., NixOS vs macOS vs Windows).
- **User-specific vars**: set `userSpecific = true` in the catalog entry for vars whose value depends on the logged-in user (e.g. `PASSWORD_STORE_DIR`). These are excluded from `toNixOSSystemEnvironment` (system-wide env) and only set via home-manager session variables.

## Scope restrictions

Valid reasons to restrict scope:
- The variable would cause incorrect behavior for unintended consumers (e.g., `CC`/`CXX`/`LD` on macOS: Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery). Absolute Nix store paths (`${pkgs.llvmPackages.clang}/bin/clang` etc.) prevent bare-name resolution to `/usr/bin/clang` which triggers the Xcode `xcrun` installation dialog.
- The concept is inherently platform-specific (e.g., `DEVELOPER_DIR` on non-macOS hosts). On macOS, `DEVELOPER_DIR` points at `pkgs.apple-sdk` so `xcrun --sdk macosx --show-sdk-path` works without Xcode CLT installed. A system-level `xcode-select --switch` (in `src/hosts/MacBook/activation.nix`) covers non-shell process trees.
- The value is technically infeasible to compute at build time (e.g., `NUCLEUS_REPO_ROOT` on NixOS — captured at eval time).

"CLI-only tool" or "only shells need it" is not a valid restriction on NixOS or Windows — both CLI and GUI processes inherit the same environment. On macOS, a second propagation mechanism (LaunchAgent calling `launchctl setenv`) is required because `launchd` maintains separate shell and GUI domains.
