---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

Every env var is all-process by default. Narrower scope needs an inline `# WHY:` comment.

## Registry

The `catalog` in `src/modules/lib/env-secrets.nix` holds per-host `values`, a `why`, and an optional `userSpecific` flag. Helpers: `allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`. PATH lives separately in `src/modules/lib/managed-paths.nix`, where `pathComponents.prepend` and `pathComponents.append` are separate lists and both need handling.

On Windows, `nucleus-apply` self-elevates and the DSC mirror keeps the same split: non-user-specific entries go to `system/env.dsc.yml` at Machine scope, user-specific ones to `user/env.dsc.yml` at User scope. Elevation failure is a hard error.

An entry keyed to a single host resolves to null elsewhere, and consumers guard on that rather than substituting a default, so a host that manages no such value keeps whatever its session environment provides.

## Delivery

The catalog is the single source of truth for anything that must reach more than one surface: POSIX shells read `allVars` through Home Manager session variables, macOS GUI processes read `macBookAllVars` through the `gui-env` agent (`launchctl setenv`), and PowerShell reads the value substituted into its profile by `src/modules/pwsh.nix` (`init.ps1`) or `Sync-ShellProfile.ps1`.

A framework export that reaches one shell family is not enough. nix-darwin, for example, exports the GPG agent environment for zsh, bash, and fish from the snippet it sources in `/etc/zshenv`, so a PowerShell started outside a zsh parent has no `SSH_AUTH_SOCK` and falls back to an `IdentityFile` it cannot read. A value a provisioned shell or GUI process needs belongs in the catalog, or the uncovered surface carries a `# WHY:`.

## Cross-host exceptions

| Var | macOS | NixOS | Windows | Rationale |
| --- | --- | --- | --- | --- |
| `NUCLEUS_REPO_ROOT` | `/Library/Application Support/nucleus/repo-root` + session/GUI env | `/var/lib/nucleus/repo-root` + `environment.variables` | Machine registry via `apply.ps1` | All-process root for out-of-store symlinks + cwd-independent commands. POSIX matches Windows Machine scope. |
| `NIX_SSL_CERT_FILE` | daemon env | none | none | No system CA bundle on macOS. |
| `NUCLEUS_HOST` | daemon env | daemon env | none | Not meaningful on Windows. |
| `OLLAMA_HOST` | gui-env agent | none | none | CLI routes via LiteLLM proxy. |

Everything else is the same value at the same scope on every host.

## Valid narrower scopes

Incorrect behavior for unintended consumers (`CC`/`CXX`/`LD` on macOS), platform-specific values (`DEVELOPER_DIR` off macOS), and values infeasible at build time (`NUCLEUS_REPO_ROOT` on NixOS). "CLI-only" is not valid on NixOS or Windows. On macOS the `launchd` domains are separate and bridged by `macos-gui-env-path`.

## Tests

`tests/integration/env-parity-tests.nix` checks the catalog against the DSC scope split, and `tests/platforms/Windows/modules/EnvVarParity.Tests.ps1` checks the Windows-only wiring. A new variable needs coverage in both.
