---
description: "Use when authoring or editing scripts under scripts/ or src/scripts/, or PowerShell modules."
name: "Script Authoring"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1, src/platforms/Windows/modules/**"
---

# Script authoring

Name scripts for their task with the runtime extension. Application code moves under `src/`; `src/scripts/apply.sh` is there because the flake embeds it as `apps.apply`. `src/hosts/<Host>/scripts/` is host-specific, `src/platforms/<Platform>/scripts/` platform-shared, and both POSIX hosts share `services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, `integrations/` (`cross-host-feature-parity.instructions.md`). Shared names are verb-first `<verb>-<target>.<ext>`, except `services/` (`<entity>-<role>.<ext>`) and `lib/` (`<domain>.sh`); host scripts take a platform prefix.

`scripts/bootstrap.sh` and `bootstrap.ps1` keep capability parity; shared pins live in `scripts/bootstrap-versions.env`. Keep scripts non-interactive, idempotent, and predictable. No Bash-only features in `.sh` unless documented; full cmdlet names over aliases. Re-check `.github/workflows/ci.yml` and instruction files when a location or behavior changes.

A sourcing script derives `SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"` exactly; never use bare `$(dirname "$0")` in a source line. Symlink-reached scripts under `scripts/` use `dirname -- "$_self"`.

Every directly invocable POSIX script sources `src/scripts/lib/bash-guard.sh` right after `SCRIPT_DIR` and calls `bash_guard_require <major> <minor> <name>` before newer constructs. `scripts/bootstrap.sh` stays bash 3.2 compatible with a comment explaining why. Sourced libs (`src/scripts/lib/*.sh`, `*-lib.sh`, loaders, step definitions) add no guard. Every directly invocable PowerShell script dots `src/scripts/lib/pwsh-guard.ps1` and calls `Assert-NucleusPowerShell -Minimum '7.0'` early (after `param()`); modules, libs, loaders, step definitions, and shell profiles are exempt.

CLI flags are `--XXX` / `--no-XXX` with bare positive shell variables (`ai_sync`, tested as `"$x" = false`), PowerShell `[switch]$AISync` / `[switch]$NoAISync` called `-AISync` / `-NoAISync`. `.sh`, `.ps1`, `.bat` keep Git mode `100755` (`git update-index --chmod=+x`); `.yml`, `.json`, `.nix`, `bootstrap-versions.env` stay `100644`. Line endings follow `.editorconfig` and `.gitattributes`. Sort unordered lists alphabetically (packages, aliases, `extraGroups`, experimental features, `case` labels, env blocks); preserve semantic order (`boot.initrd.availableKernelModules`, `imports`, catch-all `*` last); avoid new `nucleus*` Nix identifiers unless disambiguation requires them.

## Privilege gating

A privilege is required only when the operation cannot succeed without it. `src/` and non-user-facing paths hard-error when required; user-facing `scripts/` commands escalate (`sudo`, `RunAs`) and warn-and-skip only when escalation is impossible. Inverse family (`scripts/bootstrap.sh`, `bootstrap.ps1`, `src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) refuses to run elevated; Windows provisioning to `%ProgramData%\nucleus\bin` uses `RunAs` with no fallback. Non-escalatable privileges warn and skip: macOS Full Disk Access, `nucleus-apply health-check`, WHPX detection. Missing Jellyfin admin token (`.Policy.IsAdministrator`) is a configuration prerequisite and hard-errors.

`derive_repo_root()` in `src/scripts/lib/lib.sh` checks `NUCLEUS_REPO_ROOT`, the SYSTEM `repo-root` file (`/Library/Application Support/nucleus/repo-root`, `/var/lib/nucleus/repo-root`), a `SCRIPT_DIR` walk, then `git rev-parse`; `/nix/store/` values are rejected. `scripts/apply.sh` writes the live checkout path before and after rebuilds; `src/modules/posix/security.nix` preserves the env through `sudo`. A `--repo-root` flag may override but is never the only mechanism.

Runtime toggles live in `~/.local/state/nucleus/config.json`, default `true` when absent unless documented; `scripts/config.sh` / `.ps1` enforce them while services read directly for early boot. New keys need defaults in both scripts and every read site. `applyHistoryLimit` defaults `256`; `0` disables writes, negative is unlimited. Use `admin` and `guest` in examples.

`health-check` exports `SOPS_AGE_KEY_FILE` before its `sops -d` loop using `nucleus_machine_age_key_path` from `src/scripts/lib/lib.sh`, never a literal path (`sops.age.keyFile` in `src/modules/secrets.nix`, `check_secret_health()`). `src/scripts/apply.sh` runs `generate-ssh-host-key.sh` then `register-host-age-key.sh` before rebuild; the latter creates `/etc/ssh/ssh_host_ed25519_key`, derives with `ssh-to-age -i`, inserts before `    # -- machine keys end; personal SSH backup key below --` when new, rewraps SOPS, and prints `git add`/`git commit`. It needs a GPG keyring and `mkApplyApp` `runtimeInputs`; Windows uses `Register-HostAgeKey.ps1`. `adopt-ssh-key.sh` and `Sync-SecretFile` flush the SSH agent on fingerprint drift, with no `[ -n "$old_fingerprint" ]` or `-ne ''` guard, which would skip first provision.
