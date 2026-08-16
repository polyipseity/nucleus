---
description: "Use when adding or changing capabilities across hosts (macOS, NixOS, Windows), managing GC/retention timings, or creating provisioned symlinks. Enforces cross-host parity-first design, explicit rationale for platform-specific exceptions, and consistent infrastructure conventions."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

## Goal

Default to parity-first changes: apply new capabilities to as many hosts as practical in the same change. Avoid one-host features unless there is a concrete platform constraint. Keep host orchestration thin and push reusable behavior into shared modules (`src/modules/*.nix` and `src/platforms/Windows/modules/*.ps1`) or declarative state files (`src/hosts/Windows/*.dsc.yml`).

Avoid special-casing in module logic. When a feature requires per-host differences, refactor shared behavior into parameterized abstractions rather than adding `if-else` branches or duplicating files.

## What parity means

Parity means the same capability is available on every host where it is practical, with the same CLI surface (subcommands, flags, exit codes, error messages where feasible), the same declarative data (`*.json` + schema) as SSOT when applicable, the same host tooling provisioned per platform, and the same docs (`MANUAL.md` on all hosts) and tests (paired unit tests + Nix wiring).

Parity does **not** mean delegating Windows work to bash, `sh`, or `.sh` scripts; byte-identical implementation files across platforms; or identical platform primitives (launchd vs systemd vs SCM) — those differences are documented exceptions with WHY.

**Implementation pattern (default):**

- POSIX (macOS + NixOS): bash in `scripts/*.sh` or `src/scripts/**/*.sh`
- Windows: PowerShell in `scripts/*.ps1` or `src/platforms/Windows/modules/**/*.ps1`
- Shared content in the same language: single file in `src/scripts/` per `embedded-content.instructions.md`
- Windows prohibition: no `Invoke-NucleusRepoScript` with `.sh` paths; no `bash`/`sh` subprocess calls from Windows runtime code (`profile.ps1`, `vm.ps1`, `apply.ps1`, Windows modules)

**Exception:** generated `.sh` wrappers in VM trees (`pack.sh`, `start-*.sh`) exist for cross-host folder copy — Windows runs `.ps1` twins locally; nucleus Windows code does not execute those `.sh` files.

## Feature scope triage

For every new capability, evaluate all three hosts before coding:

1. macOS (`src/hosts/MacBook/` + shared modules)
2. NixOS (`src/hosts/NixOS/` + shared modules)
3. Windows (`src/hosts/Windows/` + `src/platforms/Windows/modules/`)

If a capability can exist on more than one host, implement those hosts in the same change whenever feasible.

When reducing parity debt (especially Windows vs macOS/NixOS), evaluate existing capabilities one-by-one. For each feature discovered on any host, record one explicit decision: implement parity now, already in parity, or not practical yet (with a short WHY in code and change summary). At minimum review: packages/tools, shell/dev workflow, security posture, desktop/UI behavior, remote-access behavior, secrets, editor experience, git/signing behavior, power/network posture, and automation hooks.

When reviewing desktop/UI behavior, apply a minimal-chrome parity lens: prefer reducing persistent chrome (menu extras, taskbar buttons, recents, always-visible docks/panels) when equivalent keyboard/command workflows remain available. At the same time, preserve high-signal visibility defaults (hidden files, file extensions, status/path bars, and explicit metadata) unless there is a concrete host constraint.

### Host-specific lib/ pattern for per-host config differences

When a config file's application has a native extension-point mechanism that auto-loads override scripts (e.g., direnv's `~/.config/direnv/lib/*.sh`), use the Host-specific lib/ subdirectory convention documented in `app-config-policy.instructions.md`. This avoids `if-else` branches in module logic and avoids deploying dead platform-specific code.

## Where to implement

- **POSIX shared behavior** (macOS and NixOS): centralize in `src/modules/*.nix`.
- **Windows declarative state**: prefer DSC YAML files (`system.dsc.yml`, `system-packages.dsc.yml`, `user.dsc.yml`, `user-env.dsc.yml`, `user-context.dsc.yml`) when a WinGet DSC resource can represent it.
- **Windows reusable imperative logic**: keep in `src/platforms/Windows/modules/*.ps1`; keep `src/hosts/Windows/apply.ps1` orchestration-only.
- If a Windows parity feature cannot be represented declaratively, implement it in a reusable module with an explicit cleanup/deconfiguration path so the feature can be safely disabled later.

## Imperative fallback safety (Windows)

If a parity feature requires imperative Windows code, enforce all of the following in both configuration and deconfiguration paths:

- **Managed-scope only**: change only declaratively managed blocks/keys/files; never overwrite, delete, or mutate unrelated user-managed content.
- **Fail-fast on unsafe state**: stop with a clear error when ownership, preconditions, or target state are ambiguous.
- **Idempotent convergence**: repeated applies must not duplicate managed content or repeatedly mutate equivalent values.
- **Idempotent cleanup**: disabling a feature must remove only managed state and be a no-op when that managed state is already absent.
- **Explicit toggle wiring**: expose enable/disable in `src/hosts/Windows/apply.ps1` and wire cleanup when disabled.

## Service lifecycle cleanup

When a service declaration is removed or disabled:

- **macOS (launchd) / NixOS (systemd)** — Automatic. Nix removes the unit file and stops the service on re-apply.
- **Windows native SCM services** (Caddy, LiteLLM) — Explicit. Each `Sync-*Service.ps1` module implements its own cleanup when `-Enabled:$false`: `Stop-Service` + `sc.exe delete`.
- **Windows scheduled tasks** (cloud-drive, CamillaDSP, Discord Music RPC, etc.) — Same explicit pattern. Each `Sync-*` module calls `Unregister-ScheduledTask` when disabled.

When adding a new Windows service module, always implement both the enable and disable paths. Verify disable removes the managed service/task state completely.

Services that fail to start during activation emit a warning but do not abort the activation. This applies to all hosts. Watchdog retries are handled separately per service.

## Service firing policy

### Default policy: persistent daemon

All nucleus-managed services use persistent-daemon semantics by default: auto-start on boot/login and auto-restart on crash. This ensures uniform, predictable service lifecycle across all hosts with no manual recovery needed after transient failures.

#### Default templates per platform

|                   | Persistent daemon (auto-start + crash recovery)                                                                                                                                                                                      | Periodic oneshot (timer-triggered, exit between runs)                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| **macOS launchd** | `RunAtLoad = true; KeepAlive = true;`                                                                                                                                                                                                | `StartInterval` or `StartCalendarInterval`; `KeepAlive = false`; `RunAtLoad = false` (or `true` if an immediate first tick is desired) |
| **NixOS systemd** | `wantedBy = ["multi-user.target"]` (system) or `["default.target"]` (user); `serviceConfig.Restart = "always"`                                                                                                                       | `systemd.timers` (calendar or `OnUnitActiveSec`) + `Type = "oneshot"` service                                                          |
| **Windows**       | SCM: `StartType = Automatic`; scheduled task: `AtLogOn` (user) or `AtStartup` (system) with `AllowStartIfOnBatteries`, `DontStopIfGoingOnBatteries`, `StartWhenAvailable`. Scripts with internal `while ($true)` loop for keepalive. | Scheduled task with calendar trigger or `Once` + `Repetition`                                                                          |

#### Persistent daemons (default)

| Service                   | macOS                                       | NixOS                     | Windows                |
| ------------------------- | ------------------------------------------- | ------------------------- | ---------------------- |
| `caddy`                   | launchd `daemon`, system                    | SCM                       | SCM                    |
| `camilladsp`              | launchd `daemon`, system                    | systemd `service`, system | scheduled task, user   |
| `camilladsp-heartbeat`    | launchd `daemon`, system                    | systemd `service`, system | scheduled task, user   |
| `camillagui-backend`      | launchd `daemon`, system                    | systemd `service`, system | scheduled task, user   |
| `cloud-drive`             | launchd `agent`, user                       | systemd `service`, user   | scheduled task, user   |
| `discord-music-rpc`       | launchd `agent`, user                       | systemd `service`, user   | scheduled task, user   |
| `jellyfin`                | launchd `daemon`, system                    | systemd `service`, system | SCM                    |
| `linux-builder`           | launchd `daemon`, system                    | — (N/A)                   | — (N/A)                |
| `litellm`                 | launchd `daemon`, system                    | systemd `service`, system | SCM                    |
| `ollama`                  | launchd `daemon`, system                    | systemd `service`, system | SCM                    |
| `rdp`                     | — (N/A)                                     | — (N/A)                   | SCM                    |
| `service-watchdog`        | launchd `daemon`, system                    | systemd `service`, system | scheduled task, system |
| `service-watchdog-user`   | launchd `agent`, user                       | — (N/A)                   | — (N/A)                |
| `ssh-agent`               | launchd `agent`, user (built-in)            | systemd `service`, user   | SCM                    |
| `sshd`                    | launchd `daemon`, system (socket-activated) | systemd `service`, system | SCM                    |
| `betterdisplay-heartbeat` | launchd `agent`, user                       | — (N/A)                   | — (N/A)                |

#### Periodic oneshots (exceptions)

| Service                    | macOS                                                | NixOS                                                  | Windows                            | Rationale                                                                                |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------ | ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `gc-weekly`                | launchd `daemon`, StartCalendarInterval (Sun 12:00)  | systemd `timer`, system (Sun 12:00, `Persistent=true`) | scheduled task (Weekly, Sun 12:00) | Runs full `gc.sh` as root; user homedir steps via `sudo -u` |
| `nix-index-update`         | launchd `agent`, StartCalendarInterval (daily 12:00) | systemd `timer`, user (daily 12:00, `Persistent=true`) | — (N/A)                            | Daily rebuild with freshness guard; not applicable on Windows (no nix ecosystem)         |
| `dev-ds-store-gc`          | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A)                                                | — (N/A)                            | macOS-only; Finder `.DS_Store` cleanup                                                   |
| `dev-spotlight-exclusions` | launchd `agent`, StartCalendarInterval (daily 12:00) | — (N/A)                                                | — (N/A)                            | macOS-only; Spotlight metadata markers                                                   |
| `icloud-exclusions`        | launchd `agent`, StartInterval=3600                  | — (N/A)                                                | — (N/A)                            | macOS-only; iCloud ignore xattr drift correction                                         |

- **`gc-weekly` log overlap:** runs full `gc.sh` including log rotate/expire; daily `log-gc-user` / `log-gc-system` cover the same paths — overlap is intentional and idempotent.
- **`duperemove` (NixOS only):** weekly root `gc.sh` runs btrfs block dedup on `/nix/store` after `nix-collect-garbage`. No macOS/Windows parity — those hosts have no Nix store on btrfs.

### Explicit recovery settings removed

Service configurations do not set explicit rate-limiting or restart-interval settings (`ThrottleInterval` on macOS, `RestartSec` on NixOS, `RestartCount`/`RestartInterval` on Windows). Platform defaults are sufficient because the internal loop pattern handles keepalive pacing — the service manager only needs crash recovery (launchd's default throttle is shorter than the explicit 30 s; systemd's default `RestartSec` is 100 ms; Windows scheduled tasks do not restart automatically — the internal loop handles keepalive).

### Internal loop pattern (heartbeat and watchdog)

Services that need periodic work but must stay registered as persistent daemons use an internal sleep loop instead of platform timer mechanisms:

```bash
# POSIX (shell script)
while true; do
  do_work "$@"
  sleep "$INTERVAL"
done
```

```powershell
# Windows (PowerShell)
while ($true) {
  Do-Work
  Start-Seconds -Seconds $Interval
}
```

#### Exponential backoff (camilladsp-heartbeat)

The `camilladsp-heartbeat` script uses exponential backoff instead of a fixed sleep interval. This prevents rapid retry loops when CamillaDSP is down for an extended period (e.g., audio device disconnected, daemon restarting).

- **Base delay**: 5 s
- **Maximum delay**: 300 s
- **Algorithm**: on failure, `sleep = min(current × 2, max)`. On success, reset to base delay immediately.

The service-watchdog and betterdisplay-heartbeat use fixed intervals (300 s and 30 s, respectively) because their work is lightweight and failure recovery does not benefit from backoff.

This pattern applies to:

- `camilladsp-heartbeat` (5 s base, exponential backoff to 300 s max)
- `service-watchdog` (300 s fixed loop, system scope)
- `service-watchdog-user` (300 s fixed loop, user scope)
- `betterdisplay-heartbeat` (30 s fixed loop)

Benefits:

- Platform timer mechanisms (StartInterval, systemd timers, scheduled-task repetition) become crash recovery only — the daemon always looks "running" instead of repeatedly spawning short-lived processes.
- Unified service lifecycle monitoring (process is always alive).
- Fixes the Windows scheduled-task `Duration` cap (P1D on the watchdog was causing the task to stop repeating after 24 h).

### macOS-only services

These services are specific to macOS and have no cross-host equivalent:

| Service                    | Reason                                                                                                                                                                |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `betterdisplay-heartbeat`  | BetterDisplay is a macOS-only app for virtual screens                                                                                                                 |
| `dev-ds-store-gc`          | `.DS_Store` is a Finder/Spotlight macOS convention                                                                                                                    |
| `dev-spotlight-exclusions` | `.metadata_never_index` is a macOS filesystem attribute                                                                                                               |
| `icloud-exclusions`        | `com.apple.fileprovider.ignore#P` xattr is macOS-only                                                                                                                 |
| `gui-env`                  | `macos-gui-env-path` activation step sets all vars via `launchctl setenv` + `launchctl config user path`; one-shot `gui-env` LaunchAgent provides login-time coverage |
| `linux-builder`            | Nix Linux builder VM is macOS-specific (NixOS runs Linux natively)                                                                                                    |

### POSIX-only services

Services that exist on macOS and NixOS but not on Windows:

| Service            | Rationale                                                                         |
| ------------------ | --------------------------------------------------------------------------------- |
| `nix-index-update` | nix-index is part of the Nix ecosystem; Windows uses Scoop for package management |

### ssh-agent and sshd

All hosts use the OS-native SSH agent and server, with no custom service definitions:

| Host        | ssh-agent                                                           | sshd                                                                 |
| ----------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **macOS**   | Built-in `com.openssh.ssh-agent` launchd user agent (defined by OS) | Built-in `com.openssh.sshd` launchd system daemon (socket-activated) |
| **NixOS**   | `programs.ssh.startAgent = true` (systemd user service)             | `services.openssh.enable = true` (systemd system service)            |
| **Windows** | Built-in `ssh-agent` SCM service (Windows OpenSSH)                  | Built-in `sshd` SCM service (Windows OpenSSH, installed via WinGet)  |

## Package parity rules

- When adding a cross-host CLI tool to `src/modules/core.nix`, check whether a Windows equivalent should be added to `src/hosts/Windows/system-packages.dsc.yml`.
- When adding a Windows CLI package to `system-packages.dsc.yml`, check whether POSIX hosts should also receive it through `core.nix`.
- When adding a package that exists in both nixpkgs and Homebrew, add it to `overlappingPackages` in `src/modules/core.nix` (not spread across host files). See `package-installation-scope.instructions.md` (Overlapping package classification) for category, platform, and add-workflow rules.
- Remove duplicate declarations from `src/hosts/NixOS/desktop.nix` when a package is already delivered via `core.nix`'s `sharedPackages`.
- Windows source builds use git hash pinning. When a tool must be compiled from source on Windows, pin by git commit hash, not a tag or branch. Document the build steps in a reusable `Build-<Tool>.ps1` module under `src/platforms/Windows/modules/` and wire it into the activation DAG in `apply.ps1`.

## Secrets and wallpaper parity

- POSIX secrets: `src/modules/secrets.nix` + `materialize-user-secrets.sh`; Windows: `Sync-UserSecret.ps1` / `Sync-SecretFile.ps1` wired by `apply.ps1`.
- POSIX wallpapers: `src/modules/wallpapers.nix`; Windows: `src/platforms/Windows/modules/wallpapers/Sync-WallpaperInventory.ps1` + `user.dsc.yml`.
- Stale cleanup rules must be preserved on every host implementation.

## Cloud-drive parity

See `cloud-drives-and-finder.instructions.md` for the full cloud-drive policy. Key parity requirements: treat mounts/replicas parity-first across all hosts, keep managed paths as real directories on all hosts (see cloud-drives-and-finder for the macOS-only iCloud exception), and do not add push/bisync execution paths for replicas.

## Cross-platform script deduplication

Scripts under `src/hosts/<Host>/scripts/` or `src/platforms/<Platform>/scripts/` must implement a feature that is semantically host- or platform-specific. If the feature could apply to any POSIX host, the script belongs in a non-host subdirectory (`services/`, `configs/`, `packages/`, `editors/`, `secrets/`, `shell/`, `agents/`, `lib/`, or root of `src/scripts/`).

When the same feature exists on both macOS and NixOS with host-specific implementations, the scripts SHOULD be merged into a single POSIX-compatible script using `builtins.replaceStrings` token substitution (preferred) or `case "$(uname)"` dispatch in the script body. Merged scripts MUST NOT use the `macos-` or `nixos-` prefix; they use natural names per the naming rule. After merging, delete the original host-specific scripts — no backwards-compatibility shims.

## Allowed platform-specific exceptions

Single-host implementation is allowed only when the feature depends on platform-specific primitives (for example: macOS defaults domains, NixOS kernel modules, Windows registry/DSC resources). When that happens, add a short WHY comment in code explaining why parity is not possible or not desirable. If an exception hides information or controls (for example auto-hide, taskbar/menu toggles, or hidden-file toggles), the WHY comment must explain the tradeoff and name the alternate access path (shortcut, command, or menu route).

## Pre-merge parity checklist

- Feature scope evaluated for all three hosts (macOS, NixOS, Windows).
- Multi-host implementation done where practical; exceptions have WHY comments.
- Shared logic extracted into shared modules where possible.
- Related instructions/AGENTS guidance updated when invariants changed.

## GC and retention policy

Timing values are specified directly at their point of use. Find or change a retention interval in the relevant source file:

| Category                     | Source files                                                                                                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix store GC, HM expiry      | `src/modules/posix-base.nix`, `src/scripts/services/nix-store-gc.sh`, `scripts/gc.sh`, `src/modules/lib/gc-options.nix` |
| macOS timers & defaults      | `src/platforms/macOS/modules/default.nix`, `src/hosts/MacBook/defaults.nix`                                                                                                                                                                                   |
| Linux timers & timeouts      | `src/platforms/NixOS/modules/default.nix`, `src/modules/posix-security.nix`                                                                                                                                                                                   |
| Windows schedules & timeouts | `src/hosts/Windows/system.dsc.yml`, `src/hosts/Windows/system-packages.dsc.yml`, `src/hosts/Windows/user.dsc.yml`, `src/hosts/Windows/user-env.dsc.yml`, `src/hosts/Windows/user-context.dsc.yml`, `src/platforms/Windows/modules/system/*.ps1` |
| Cloud drive caches           | `src/modules/cloud-drives.nix`                                                                                                                                                                                                              |
| AI/LLM timeouts              | `scripts/ai-sync.sh`, `scripts/gc.sh`                                                                                                                                                                                                       |
| Declarative-diff GC items    | `scripts/gc.sh`, `scripts/gc.ps1`                                                                                                                                                                                                           |
| App-level timeouts           | `src/modules/editors.nix`, `src/users/default/picard/Picard.ini`                                                                                                                                                                          |

Runtime overrides via `--expiry`/`NUCLEUS_GC_EXPIRY` and `--generations-keep`/`NUCLEUS_GC_GENERATIONS_KEEP` etc. have precedence: CLI flag > per-tool env var > master flag/env > Nix config default > `7d` / `7`. When changing a timing value, update the actual configuration in the source file listed above. No separate timing manifest needs updating.

## Provisioned symlink policy

Every provisioned symlink must be writable AND delete-protected.

- **Delete-protection mechanism**: `chflags uchg` (macOS), `chattr +i` (Linux), `icacls /deny` (Windows). Best-effort with warning on failure.
- **Read-only exception**: A symlink MUST be read-only when its target is in the Nix store (or on Windows, when the corresponding POSIX symlink uses a Nix store target). The Nix store target is immutable, making the content effectively read-only.
- **Deviation rule**: Any deviation from the default or read-only exception must be documented with a `# WHY:` comment at the creation site and an entry in the exceptions list below.

When a symlink exists on both POSIX and Windows, writability semantics MUST match. A read-only symlink on POSIX (Nix store target) must be made read-only on Windows (read-only attribute or restrictive ACL).

### macOS /usr/local/bin symlink farm

`src/hosts/MacBook/scripts/macos-symlink-farm.sh` manages `/usr/local/bin` symlinks for Nix store entries. It reads `__nucleus_symlink_farm` (space-separated `target->name` pairs), creates/updates symlinks, and GCs stale Nix store entries. Safety: only removes symlinks (`-L`), never regular files, never non-Nix symlinks.

The `__nucleus_symlink_farm` env var is generated in `src/hosts/MacBook/activation.nix` from `appleSdkTools.symlinkFarmTools` plus any extra entries.

## Host vs platform naming

### Three layers

| Layer | Values | Role |
| ----- | ------ | ---- |
| **Host** | `MacBook`, `NixOS`, `Windows` | Primary lookup key: services, env-catalog, config paths, flake attrs, `NUCLEUS_HOST`, user registry maps |
| **Platform** | `macOS`, `NixOS`, `Windows` | OS-family entity; owns `flags` (`darwin`, `posix`, `linux`, `win32`); VM guest `type` |
| **Implementation** | `uname`, `stdenv.isDarwin`, nixpkgs `system` | Boundary only — map immediately via `host-platform-registry.json` |

### Rules

- Host JSON entries reference platform by name only (`"platform": "macOS"`). **Never put flags on host objects.**
- Flags live in `host-platform-registry.json` → `platforms.<PlatformKey>.flags` only.
- Lookup host first. When flags are needed: `platformForHost(host)` → `flagsForPlatform(platform)`.
- `services.json` uses `hosts.MacBook|NixOS|Windows`, not `platforms.macos|nixos|windows`.
- Flake configuration attrs: `darwinConfigurations.MacBook`, `nixosConfigurations.NixOS`.
- Env-catalog `values` keys and `resolveValue` use host names (`MacBook`, not `macOS`).
- Config paths under `src/modules/configs/` use host directory names (`MacBook/`, `NixOS/`, `Windows/`).
- Script prefixes (`macos-`, `nixos-`) and nixpkgs `meta.platforms` are implementation boundaries — do not rename to host keys.

### Decision tree

1. Is the data keyed by physical machine identity? → **Host key** (`MacBook`, `NixOS`, `Windows`).
2. Is the data about OS-family semantics or implementation flags? → **Platform key** (`macOS`, `NixOS`, `Windows`).
3. Is the data from nixpkgs, kernel, or third-party API? → Keep upstream naming; map at the boundary via registry helpers.

### Canonical helpers

| Surface | Host resolution | Platform / flags |
| ------- | --------------- | ---------------- |
| Nix | `host-platform.nix` → `platformForHost`, `flagsForHost` | `flagsForPlatform` |
| POSIX shell | `resolve_nucleus_host` | `nucleus_platform_for_host`, `nucleus_flag_for_host` |
| PowerShell | `Get-NucleusHostKey` (`$env:NUCLEUS_HOST` or `Windows`) | `Get-NucleusPlatformForHost`, `Test-NucleusPlatformFlag` in `Get-NucleusHostPlatform.ps1` |

### SSOT files

- `src/modules/host-platform-registry.json` — host → platform refs; platform → flags
- `src/modules/services.json` — per-service `hosts.*` with required `platform` field
- `src/modules/lib/env-catalog.nix` — `values.MacBook|NixOS|Windows`

### Audit

Host vs platform vs implementation naming is enforced by service-registry validation (check step 8) and documented in this section.

## Cross-surface identifier mapping

The same activation or apply step is named across five identifier surfaces. Each surface keeps its platform-native format; this table is the canonical cross-boundary reference.

| Surface | Convention | Example |
| ------- | ---------- | ------- |
| Nix/POSIX activation entries (`home.activation.*`, `system.activationScripts.*`, `nucleus.terminalActivations.*`) | kebab-case, verb-first (see `activation-scripts.instructions.md`) | `write-terminal-activations` |
| DSC file IDs | `<scope>/<kebab-name>.dsc.yml` | `user/shell.dsc.yml` |
| PowerShell functions/modules | PascalCase with approved verbs (`Sync-*`, `Deploy-*`, `Invoke-*`, `Get-*`, `Set-*`), enforced by `scripts/pwsh-naming-manifest.json` | `Sync-TerminalActivation` |
| POSIX apply step functions (`src/scripts/apply.sh`) | snake_case `run_*` | `run_terminal_activations` |
| Stage labels (`src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) | `<label>:` kebab-case | `terminal-activations:` |

### Worked cross-boundary pair

`write-terminal-activations` (activation entry) ↔ `Sync-TerminalActivation` (PowerShell) ↔ `terminal-activations:` (stage label) ↔ `run_terminal_activations` (apply function) name the same step across all surfaces. The singular/plural asymmetry is deliberate: the PowerShell verb is singular `Sync-TerminalActivation` (renamed from `Sync-TerminalActivations` in commit "fix(pwsh): rename Sync-TerminalActivations to Sync-TerminalActivation"), while the activation entry and stage label use plural. Do NOT "fix" this — the mapping documents the asymmetry as-is.

### Kept-as-is decisions

- `Disable-SteamAutoStartup` keeps the approved `Disable` verb.
- `config-utils.nix` generated names (`unprotectSymlink_${name}` etc.) are exempt from the kebab-case rule; the Windows side mirrors this exemption with `ConfigHelpers.ps1` `Deploy-*` generated names.

### Known stage-label gaps

Documented but NOT fixed — intentional parity gaps for future work:

- POSIX `apply.sh` lacks the `svc:`, `vm-setup:`, `vm-sync:` labels that Windows `apply.ps1` emits.
- Windows `apply.ps1` lacks the `health-check:` and `caddy-local-ca-trust:` labels that POSIX emits.
