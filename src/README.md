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
