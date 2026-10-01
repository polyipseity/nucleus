---
description: "Use when adding or editing agents configuration, skill management, or ClawHub provisioning."
name: "Agents and Skills"
applyTo: "src/modules/agents.nix, src/modules/cursor.nix, src/modules/hermes-agent.nix, src/platforms/Windows/modules/user/Sync-AgentsSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-AgentsClawHubSkillManifest.ps1, src/platforms/Windows/modules/user/Sync-CursorConfig.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1, src/platforms/Windows/modules/user/Sync-PiAgentConfig.ps1, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-HarnessBridge.ps1, src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1, src/platforms/Windows/modules/setup/Invoke-PiSetup.ps1, src/scripts/notify/**, src/users/*/agents/**, src/users/*/cursor/**, src/users/*/hermes/plugins/**, src/users/*/opencode/**, src/users/*/pi/**, src/users/*/srt/**, src/scripts/agents/**/*.sh, src/scripts/configs/symlink-cursor-config.sh, tests/modules/harness-bridge-tests.nix"
---

# Agents and skills

## Repo tree vs user overlay

`.agents/` holds project-tied instructions, prompts, and skills. `src/users/default/agents/` is the user overlay that deploys to `~/.agents/`, with per-user overrides under `src/users/<user>/agents/`. Edit the source tree, never `~/.agents/`: every file there is a symlink into it.

`~/.agents/` is a writable directory holding per-subdir symlinks, not one whole-directory symlink.

## Cursor bridge (`~/.cursor/`)

`symlink-cursor-config` / `Sync-CursorConfig` symlink shared content into `~/.cursor/`. Edit shared rules, agents, prompts, and skills under `src/users/default/agents/`; Cursor-native JSON under `src/users/default/cursor/`. GUI settings belong in the app's own user settings.

Instruction files reach `~/.cursor/rules/` with a `.mdc` extension, which is what Copilot reads.

## Agent config bridges

`symlink-pi-agent-config` / `Sync-PiAgentConfig` and `symlink-agent-config` / `Sync-OpenCodeConfig` deploy the shared assets into `~/.pi/agent/` and `~/.config/opencode/`. opencode uses `~/.config/opencode/` on every platform, including `%USERPROFILE%\.config\opencode\` on Windows. Windows resolves the sources through the `Resolve-UserConfig*` overlay helpers.

Pi's extension set comes from the `pi` list in `src/modules/packages/desired.json`, pinned by the lockfile `pi` section, and pi records what it installed in `~/.pi/agent/settings.json`. Read that registry, never a listing of `~/.pi/agent/npm/`, which holds `node_modules`.

## Bundled vs fetched skills

Bundled (AGPL-compatible: MIT, BSD, Apache-2.0, AGPL): commit to `src/users/default/agents/skills/<name>/`, and `install-agent-skills` symlinks it into the store.

Fetched (proprietary, CC-NC, GPL-only): never commit. List the slug in `src/users/default/agents/clawhub-skills.json`; `sync-clawhub-skills` downloads it at apply time. `.clawhub/origin.json` marks a fetched download and stale cleanup removes only directories carrying it. A slug that matches a bundled symlink warns and skips; resolve it by hand.

Layered: `install-agent-skills` / `Sync-AgentsSkillManifest` take an extra source directory, used to layer the superpowers plugin's `skills/` in alongside the committed skills. The primary source is the `skills` entry of the agents overlay, resolved through the overlay helpers, never a hardcoded `src/modules/configs/agents/skills` path.

## Permission locking

Installed files are locked read-only and unlocked before update. POSIX: `chmod -R a-w` / `u+w`. Windows: `FileAttributes.ReadOnly` via `Get-ChildItem -Recurse`. `Sync-SecretFile` adds `$restrictAcl` (`icacls /inheritance:r /grant:r`).

## ClawHub provisioning

ClawHub is a JS CLI absent from nixpkgs, cargo-binstall, WinGet, and Scoop, so it installs through bun only. POSIX: the `install-bun-packages` HM activation in `src/modules/agents.nix` prepends `~/.bun/bin`, keeps the desired list, installs and removes as needed, and persists `~/.bun/install/global/package.json`. Windows: `Invoke-BunSetup` installs the `bun` desired list from `src/modules/packages/desired.json` into `~\.bun\install\global\package.json`, after the WinGet DSC and before the skill syncs.

## Harness bridge

`harness-notify`, `harness-approval`, and `harness-drive` live in `src/scripts/notify/`, each with a PowerShell twin. The shared hook definitions (`src/users/default/agents/hooks/harness-notify.json` for VS Code, `src/users/default/cursor/hooks.json` for Cursor) name bare commands, so every host has to resolve them through PATH: POSIX deploys them from `src/modules/agents.nix`, Windows copies them into the USER root and reaches them through `.cmd` shims on the managed PATH (`Sync-HarnessBridge.ps1`). Harness-specific glue stays with its harness: pi extensions under `src/users/<user>/pi/extensions/`, the opencode plugin at `src/users/<user>/opencode/plugins/`, wired by `seed-opencode-notify-plugin`.

Rules: hooks always exit 0 and fail open, so an unanswered approval becomes a local prompt and never a denial; every hook `timeout` must exceed `harness-approval.timeout-seconds`; a hook command stays a bare name with no home expansion or absolute path, since one JSON file drives every host; the queued-prompt file is consumed before it is printed, the only loop guard.

`harness-notify.enable` is the master switch. `harness-approval.enable` (off by default) gates only the remote approval wait. `harness-drive.enable` (on by default) gates only prompt injection: with it off a finished turn is still announced and a queued prompt is dropped. Cursor ignores `followup_message` on Windows, so Cursor is driveable from macOS and NixOS only.

Transport is the Hermes plugin `src/users/default/hermes/plugins/harness-bridge/` (`/harness status|approve|deny|send|sessions`), enabled by `services.hermes-agent.settings.plugins.enabled` and, on Windows, by `Sync-HermesConfig`. Requests and queued prompts live under `<USER root>/state/harness-bridge/`, decisions in `<USER root>/logs/harness-bridge.log` (`log` on Windows).

## Sandbox unix sockets

`srt` is `@anthropic-ai/sandbox-runtime`, and pi runs inside it. On macOS it builds a Seatbelt profile and emits each `network.allowUnixSockets` entry literally, with no `realpath`. Seatbelt matches the kernel's canonical path, so an entry spelled through a symlink matches nothing and the failure is silent.

`/private/var/run/nix-daemon.socket` is the spelling that must be present, because `/var/run` is a symlink to `/private/var/run`. Keep the other spellings (`/nix/var/nix/daemon-socket/socket`, `/var/run/nix-daemon.socket`): they cost nothing and cover a socket that is not behind a symlink. Do not prune them as duplicates.

Symptom when the resolved spelling is missing: `EPERM` on the daemon socket from any nix command, which blocks `nix run ./src#check` and `./src#test`. `EPERM` is the tell, since a socket with no listener gives `ECONNREFUSED`. `nix eval` is not a usable probe, because it passes without touching the store.

## Authoring rules

- Sync functions must not install ClawHub; provisioning is `install-bun-packages` / `Invoke-BunSetup`.
- Stale cleanup removes only directories carrying `.clawhub/origin.json`.
- Skill sync is best-effort: warn on failure, continue.
- Package lists are sorted alphabetically.
