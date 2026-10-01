---
description: "Use when authoring or editing scripts under scripts/ or src/scripts/, or PowerShell modules under src/platforms/Windows/modules/. Covers placement, naming, CLI conventions, CWD independence, privilege-gating, and cross-platform patterns."
name: "Script Authoring"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1, src/platforms/Windows/modules/**"
---

# Script authoring

## Placement and naming

Name a script for the task it performs and pick the extension matching the runtime. Move it into `src/` once it is application code rather than repo automation. `src/scripts/apply.sh` lives under `src/` because the flake embeds it as `apps.apply`; doc and line-ending rules are the same as for `scripts/`.

`src/hosts/<Host>/scripts/` is host-specific, `src/platforms/<Platform>/scripts/` is platform-shared, and anything applicable to both POSIX hosts belongs in a shared subdirectory (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, `integrations/`). Deduplication policy is in `cross-host-feature-parity.instructions.md`. Shared subdirectories are verb-first (`<verb>-<target>.<ext>`), except `services/` which is entity-first (`<entity>-<role>.<ext>`) and `lib/` (`<domain>.sh`); host-specific scripts take a platform prefix.

## Cross-platform coordination

`scripts/bootstrap.sh` and `scripts/bootstrap.ps1` are paired entry points for the same intent and keep capability parity: add a dependency on one platform and add it to the other in the same change. Shared version pins live in `scripts/bootstrap-versions.env`.

Keep scripts non-interactive with predictable exit codes and idempotent operations. No Bash-only features in `.sh` unless documented, and full cmdlet names over PowerShell aliases. When a script's location or behavior changes, re-check `.github/workflows/ci.yml` and any instruction file that names it.

## Relative pathing convention

A script that sources another file derives its own directory and sources relative to that, exactly `SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"`. `pwd -P` resolves symlinks and `CDPATH=''` prevents interference. Never use bare `$(dirname "$0")` in a source line. Scripts under `scripts/` reached through a symlink use `dirname -- "$_self"`.

## CLI option and variable naming

Use `--XXX` / `--no-XXX` flag pairs, and a bare positive shell variable name (`ai_sync`, not `do_ai_sync`) with conditions testing `"$x" = false`.

| Aspect | Convention |
| ----------------- | --------------------------------------------------------- |
| POSIX CLI flag | `--ai-sync` / `--no-ai-sync` |
| PowerShell param | `[switch]$AISync` + `[switch]$NoAISync` |
| PowerShell call | `-AISync` / `-NoAISync` |

## Line endings and permissions

Every `.sh`, `.ps1`, and `.bat` file must keep its executable bit in Git (`100755`, set with `git update-index --chmod=+x <path>`); non-script data files (`.yml`, `.json`, `.nix`, `bootstrap-versions.env`) must stay `100644`. Line endings follow `.editorconfig` and `.gitattributes`.

## Sorting

Sort unordered lists alphabetically: package lists, shell aliases, `extraGroups`, `nix.settings.experimental-features`, `case` branch labels, environment variable blocks. Never sort semantically significant order (`boot.initrd.availableKernelModules`, ordered `imports`, `case` branches where a catch-all `*` must match last), and avoid `nucleus*` prefixes on new Nix identifiers unless disambiguation demands it.

## Privilege-gating policy

A privilege counts as required only when the operation cannot succeed without it.

1. Default (`src/` code, non-user-facing paths): if required but unavailable, hard-error with a non-zero exit. No warn-and-continue, no degraded non-privileged path.
2. User-facing exception (`scripts/` only, the `nucleus-*` CLI set): escalate to get it (POSIX `sudo`, Windows `RunAs`), and warn-and-skip only when escalation is genuinely impossible.
3. Inverse family: scripts that manage escalation internally (`scripts/bootstrap.sh`, `scripts/bootstrap.ps1`, `src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) hard-refuse to run already elevated. Windows provisioning to `%ProgramData%\nucleus\bin` runs under `RunAs` with no non-admin fallback.
4. Non-escalatable privileges warn and skip: macOS Full Disk Access, `nucleus-apply health-check` diagnostics, `Invoke-VMSetup.ps1` WHPX detection.
5. This holds on every platform.

A missing Jellyfin admin token (`.Policy.IsAdministrator`) is not an escalation case: it is a configuration prerequisite, so it hard-errors.

## CWD independence

Every `nucleus-*` command works from any working directory. `derive_repo_root()` in `src/scripts/lib/lib.sh` resolves the root in this order: `NUCLEUS_REPO_ROOT`, the SYSTEM root `repo-root` file (macOS `/Library/Application Support/nucleus/repo-root`, NixOS `/var/lib/nucleus/repo-root`), a `SCRIPT_DIR` walk, `git rev-parse`. Values pointing into `/nix/store/` are rejected at every source, so a store snapshot can never become the repo root. `scripts/apply.sh` writes the live checkout path to that file before and after each rebuild, and `src/modules/posix/security.nix` preserves `NUCLEUS_REPO_ROOT` through `sudo`. A script-specific `--repo-root` flag is an acceptable override, never the only mechanism.

## Runtime configuration (`nucleus-config`)

Toggles live at `~/.local/state/nucleus/config.json`, outside `~/.config/` so they survive rebuilds, and resolve identically on every host. They default to `true` when absent. `scripts/config.sh` / `scripts/config.ps1` enforce them while services read the file directly for early-boot compatibility. A new toggle needs a default entry in both script implementations and the same default at every read site.

## Terminology in examples

Use `admin` for the primary or elevated user and `guest` for a secondary or unprivileged one, in code examples and documentation alike.

## apply.sh health-check SOPS identity

`health-check` must export `SOPS_AGE_KEY_FILE` at the machine age key before its `sops -d` probe loop, resolved with `nucleus_machine_age_key_path` from `src/scripts/lib/lib.sh` and never a literal path. `sops` does not search that path by default and falls through to GPG, which may lack the key. The path is the one `sops.age.keyFile` declares in `src/modules/secrets.nix`; see `check_secret_health()` in `src/scripts/apply.sh`.

## Machine age key auto-registration

`src/scripts/apply.sh` runs `secrets/generate-ssh-host-key.sh` then `secrets/register-host-age-key.sh` before `darwin-rebuild` or `nixos-rebuild`. The latter generates `/etc/ssh/ssh_host_ed25519_key` when missing, derives the machine age key with `ssh-to-age -i`, and when the key is new inserts it before the marker `    # -- machine keys end; personal SSH backup key below --`, rewraps the SOPS files, and prints the `git add`/`git commit` commands for the operator. It needs a GPG keyring and the tools from `mkApplyApp` `runtimeInputs`. Windows: `Register-HostAgeKey` in `src/platforms/Windows/modules/secrets/Register-HostAgeKey.ps1`.

## SSH key adoption

`adopt-ssh-key.sh` (POSIX) and `Sync-SecretFile` (Windows) flush the SSH agent when the recorded fingerprint differs from the newly materialized one. Do not add an `[ -n "$old_fingerprint" ]` guard on the POSIX side or an `-ne ''` guard on the Windows side: either one skips the flush on first provision and leaves stale keys.
