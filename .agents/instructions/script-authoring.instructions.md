---
description: "Use when authoring or editing scripts under scripts/ or src/scripts/, or PowerShell modules under src/platforms/Windows/modules/. Covers placement, naming, CLI conventions, CWD independence, privilege-gating, and cross-platform patterns."
name: "Script Authoring"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1, src/platforms/Windows/modules/**"
---

# Script authoring

## Placement and naming

Name scripts for the task they perform. Choose the extension matching the intended shell or runtime. Move a script into the source tree if it becomes application code rather than repo automation.

`src/scripts/apply.sh` lives under `src/` because it is embedded in the flake as `apps.apply`; same doc and line-ending rules as `scripts/`.

**Host-specific placement rule**: `src/hosts/<Host>/scripts/` = host-specific feature. `src/platforms/<Platform>/scripts/` = platform-shared behavior. Cross-platform features belong in non-host subdirectories (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, `integrations/`). See `cross-host-feature-parity.instructions.md` for deduplication policy.

## Per-directory naming patterns

Non-host subdirectories: **verb-first** (`<verb>-<target>.<ext>`, most subdirs), **entity-first** (`<entity>-<role>.<ext>`, `services/` only), **lib** (`<domain>.sh`). Host-specific scripts use `<prefix>-<verb>-<target>.<ext>` (`macos-`, `nixos-`, etc.).

## Cross-platform coordination

`scripts/bootstrap.sh` and `scripts/bootstrap.ps1` are paired entry points for the same intent — keep capability parity. When adding a dependency or behavior on one platform, update the other in the same change. Shared version pins live in `scripts/bootstrap-versions.env`.

## Relative pathing convention

All scripts that source other files must derive their directory via SCRIPT_DIR and source via SCRIPT_DIR-relative paths. Standard form:

```sh
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/relative/path"
```

`pwd -P` resolves symlinks; `CDPATH=''` prevents interference. Never use bare `$(dirname "$0")` in a source line. Scripts in `scripts/` that resolve via `$_self` (symlink-safe) use `dirname -- "$_self"` instead.

## CLI option and variable naming

Use `--XXX`/`--no-XXX` flag pairs. Shell variables use bare positive names (`ai_sync`, not `do_ai_sync`). PowerShell uses `[switch]$AISync` + `[switch]$NoAISync`.

| Aspect | Convention |
| ----------------- | --------------------------------------------------------- |
| Shell variable | `ai_sync=true` (positive, no prefix) |
| Conditional check | `if [ "$ai_sync" = false ]` |
| POSIX CLI flag | `--ai-sync` / `--no-ai-sync` |
| PowerShell param | `[switch]$AISync` + `[switch]$NoAISync` |
| PowerShell call | `-AISync` / `-NoAISync` |

## Line endings and permissions

Respect `.editorconfig` and `.gitattributes` for line endings. Every `.sh`, `.ps1`, and `.bat` script file must have its executable bit tracked in Git (`100755`). Set it with `git update-index --chmod=+x <path>`. Non-script data files (`.yml`, `.json`, `.nix`, `bootstrap-versions.env`) must remain `100644`.

## Sorting

Sort all unordered lists alphabetically: package lists, shell aliases, `extraGroups`, `nix.settings.experimental-features`, `case` branch labels, environment variable blocks. Do not sort semantically significant order (`boot.initrd.availableKernelModules`, ordered `imports`, `case` branches where matching order matters like a catch-all `*`). Avoid repository-brand prefixes (`nucleus*`) in new Nix identifiers unless needed for disambiguation.

## Portability and safety

Keep scripts non-interactive by default. Prefer explicit error handling, predictable exit codes, and idempotent operations. Do not assume Bash-only features in `.sh` unless documented. Prefer full cmdlet names over aliases in PowerShell.

## Privilege-gating policy

A privilege is "required" only when the operation cannot succeed without it.

1. **Default (`src/` code, non-user-facing paths):** if required but unavailable, **hard-error** (exit non-zero). No warn-and-continue. No fallback to a degraded non-privileged path.
2. **User-facing exception (`scripts/` only — `nucleus-*` CLI set):** escalate to obtain the privilege (POSIX: `sudo`; Windows: `RunAs`). Warn-and-skip only if escalation is genuinely impossible.
3. **Inverse family — hard-refuse when already elevated:** scripts that manage escalation internally (`scripts/bootstrap.sh`, `scripts/bootstrap.ps1`, `src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) refuse to run already-elevated. Windows provisioning to `%ProgramData%\nucleus\bin` runs under `RunAs` — no non-admin fallback.
4. **Non-escalatable privileges (warn-and-skip):** macOS Full Disk Access (TCC grant), `nucleus-apply health-check` diagnostics, `Invoke-VMSetup.ps1` WHPX detection.
5. Applies to all platforms.

**Jellyfin admin token** (`.Policy.IsAdministrator`): not covered by this policy. Missing token = hard-error, not warn-and-skip. This is a configuration-prerequisite check, not an escalation case.

## CWD independence — all `nucleus-*` commands must work from any working directory

Root resolution via `derive_repo_root()` in `src/scripts/lib/lib.sh` (priority: `NUCLEUS_REPO_ROOT` → `<SYSTEM root>/repo-root` (macOS `/Library/Application Support/nucleus/repo-root`, NixOS `/var/lib/nucleus/repo-root`) → `SCRIPT_DIR` walk → `git rev-parse`). Values that point into `/nix/store/` are rejected at every source, so a store snapshot can never be used as the repo root. `scripts/apply.sh` writes the live checkout path to `<SYSTEM root>/repo-root` before and after each rebuild; `src/modules/posix/security.nix` preserves `NUCLEUS_REPO_ROOT` through `sudo`.

Scripts must not assume cwd is inside the repository. Script-specific `--repo-root` flags are acceptable overrides but not the sole mechanism.

## Runtime configuration (`nucleus-config`)

Runtime toggles live at `~/.local/state/nucleus/config.json` (outside `~/.config/` so changes survive rebuilds), resolved identically on every host. Toggles default to `true` when absent unless the entry documents a different default; the default is enforced by `scripts/config.sh` / `scripts/config.ps1`. Services read the config file directly for early-boot compatibility. When adding a toggle: add a default entry to both script implementations, and read the key in consuming code (including direct readers) with the same default as that entry.

## Terminology in examples

Use `admin` for primary/elevated users and `guest` for secondary/unprivileged users in all code examples and documentation.

## Tooling alignment

Keep script behavior consistent with CI, `AGENTS.md`, and prompt guidance. If a script wraps project tooling, keep underlying commands discoverable. When script location or behavior changes, re-check `.github/workflows/ci.yml`, `.vscode/settings.json`, and any prompt or instruction files that reference it.

## apply.sh health-check SOPS identity

The `health-check` subcommand must export `SOPS_AGE_KEY_FILE` pointing to `/etc/sops/age/machine.txt` before its `sops -d` probe loop — `sops` does not search that path by default. Without this, `sops` falls through to GPG, which may lack the key. See `check_secret_health()` in `scripts/apply.sh`.

## Machine age key auto-registration

`apply.sh` calls `generate_ssh_host_key_if_needed` then `register_host_age_key_if_needed` before `darwin-rebuild`/`nixos-rebuild`. First checks for `/etc/ssh/ssh_host_ed25519_key`; if absent, runs `sudo env "PATH=$PATH" ssh-keygen -A` (Darwin/NixOS only). Derives machine age key via `ssh-to-age -i`; if new, inserts before the `# -- machine keys end --` marker, rewraps SOPS files, and prints `git add`/`git commit` commands (operator commits manually). Requires GPG keyring. Tools from `mkApplyApp` `runtimeInputs`. Windows: `Register-HostAgeKey` in `src/platforms/Windows/modules/secrets/Register-HostAgeKey.ps1`.

## Pre-provision key adoption semantics

`ssh-key-adopt` (POSIX) and `Sync-NucleusSecretFile` (Windows) flush the SSH agent when the recorded fingerprint differs from the newly materialized one. Three cases: (1) manifest absent, key present → flush (first provision), (2) manifest exists, key rotated → flush, (3) manifest exists, key unchanged → no flush (idempotent).

Do not add `[ -n "$old_fingerprint" ]` (POSIX) or `$oldSshFingerprint -ne ''` (Windows) guards — they would skip the flush on first provision, leaving stale keys.
