# Source tree

`src/` is the Nix flake root. It holds declarative configuration for MacBook (nix-darwin), NixOS, and Windows (WinGet DSC).

## Top level

| Path | Role |
|------|------|
| `flake.nix` / `flake.lock` | Flake entry, packages, `nix run` apps, host configurations |
| `hosts/` | Per-host modules and apply entrypoints |
| `modules/` | Shared Nix logic imported by hosts |
| `users/` | Per-user overlays — see [users/README.md](users/README.md) |
| `scripts/` | Activation and service scripts (not the repo-root `scripts/` CLI folder) |
| `secrets/` | Repo-level SOPS YAML |
| `vms/` | VM templates and per-platform artifact dirs |
| `lockfiles/` | Non-flake lockfiles; `flake.lock` must stay beside `flake.nix` |

## `hosts/`

- **MacBook** and **NixOS**: `.nix` modules, `activation.nix`, and `MANUAL.md` for steps that cannot be automated.
- **Windows**: `apply.ps1`, DSC YAML under `system/` and `user/`, reusable logic in `modules/`.

## `modules/`

Flat `*.nix` files (`home.nix`, `core.nix`, `cloud-drives.nix`, …) plus allowed subdirs: `configs/` (machine-wide singletons), `lib/` (shared helpers), `macos/`, `env/`.

Machine-wide app config belongs in `modules/configs/`. Per-user homedir config belongs under `users/`.

## `scripts/`

Internal scripts run from Nix activation, launchd/systemd units, or the repo-root `scripts/` helpers. Subdirs group by domain: `services/`, `lib/`, `secrets/`, `hosts/MacBook/`, `hosts/NixOS/`, and others. Naming rules are in `AGENTS.md`.

User-facing commands (`nucleus-gc`, `nucleus-check`, …) live in the sibling [`scripts/`](../scripts/) directory at the repo root. See [scripts/README.md](../scripts/README.md).

## Apply

Quick apply commands are in the [root README](../README.md). From this directory: `nix run .#apply` on macOS or NixOS, or `src/hosts/Windows/apply.ps1` on Windows.

Policy and invariants: `AGENTS.md` and `.agents/instructions/`.

## Directory roots

Nucleus owns at most **two native roots per host** — one USER root and one SYSTEM root, both fully native per-OS — plus a `~/.nucleus` convenience hub (Windows: `%USERPROFILE%\.nucleus`) for every user. User-intended dirs (`clouds`, `dev`, `virtual machines`, `Pictures/wallpapers`, `Downloads`) are excluded and stay as-is.

**Hard rule: nucleus code references only root paths** (`<root>/logs`, `<root>/state`, `<root>/config`, `<root>/run`, `<root>/caddy`). The physical conventional locations (`/var/log/nucleus`, `~/Library/Logs/nucleus`, `/run/nucleus`, `~/.local/state/nucleus`, …) are reached only via root→conventional symlinks created by activation (and by systemd `StateDirectory`/`LogsDirectory`/`RuntimeDirectory`). They must never appear in service runtime code. Symlink direction is fixed: `~/.nucleus` → roots, and roots → conventional targets. Never reversed. `~/.nucleus` is never a data root and is never written to by services.

```
macOS
  ~/.nucleus/user    -> ~/Library/Application Support/nucleus
  ~/.nucleus/system  -> /Library/Application Support/nucleus
  ~/Library/Application Support/nucleus/   (USER root)
    logs/   -> ~/Library/Logs/nucleus
    state/  -> ~/Library/State/nucleus
  /Library/Application Support/nucleus/    (SYSTEM root)
    logs/   -> /var/log/nucleus

NixOS
  ~/.nucleus/user    -> ~/.local/share/nucleus
  ~/.nucleus/system  -> /var/lib/nucleus
  ~/.local/share/nucleus/   (USER root)
    logs/   -> ~/.local/state/nucleus/log
  /var/lib/nucleus/         (SYSTEM root)
    logs/   -> /var/log/nucleus
    run/    -> /run/nucleus

Windows
  %USERPROFILE%\.nucleus\user    -> %LOCALAPPDATA%\nucleus
  %USERPROFILE%\.nucleus\system  -> %ProgramData%\nucleus
  %LOCALAPPDATA%\nucleus\         (USER root — LocalAppData is already conventional)
  %ProgramData%\nucleus\          (SYSTEM root — ProgramData is already conventional)
```

Accepted exceptions (not nucleus roots, left unchanged): `/usr/local/*` (impure Homebrew/fuse-t/battery), `/nix` (OS `synthetic.conf`), `%USERPROFILE%\.agents` (standard agent-tool location), `/run/secrets` (sops-nix default), `C:\ProgramData\ssh` (OS-owned), scheduled-task registry/HKLM/HKCU env vars, and `/etc/nucleus/bin` (nvim two-mechanism path).
