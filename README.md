# nucleus

`nucleus` is a cross-platform, declarative environment repository designed to be a **single source of truth** for:

- Linux system state (NixOS)
- macOS system state (`nix-darwin`)
- Windows native state (WinGet DSC)
- user-level shell/editor preferences (Home Manager)

## Repository architecture

```text
nucleus/
├── src/
│   ├── flake.nix
│   ├── hosts/
│   │   ├── macbook/
│   │   │   └── default.nix
│   │   ├── nixos/
│   │   │   └── configuration.nix
│   │   └── windows/
│   │       └── configuration.dsc.yaml
│   └── modules/
│       ├── core.nix
│       ├── home.nix
│       ├── shell/
│       │   └── default.nix
│       └── editors/
│           └── default.nix
└── scripts/
    ├── bootstrap.sh
    └── bootstrap.ps1
```

## What each layer does

- `src/modules/core.nix`: shared CLI tools (`git`, `rustup`, `ripgrep`, `fd`, `bottom`, `eza`, `zoxide`)
- `src/hosts/macbook/default.nix`: macOS defaults (keyboard repeat, dock behavior)
- `src/hosts/nixos/configuration.nix`: Linux host/system defaults and hardware baseline
- `src/hosts/windows/configuration.dsc.yaml`: Windows packages/settings/environment via WinGet DSC
- `src/modules/home.nix`: home-level shell/editor/dotfile composition across platforms

## One-liner apply commands

### macOS

```bash
nix run nix-darwin -- switch --flake ./src#macbook
```

### Linux (NixOS)

```bash
sudo nixos-rebuild switch --flake ./src#nixos
```

### Windows (Admin PowerShell)

```powershell
winget configure .\src\hosts\windows\configuration.dsc.yaml
```

## Bootstrap scripts

- Unix-like systems: `scripts/bootstrap.sh`
- Windows: `scripts/bootstrap.ps1`

These wrappers call the same platform-native commands and keep setup repeatable.

## First-run checklist

1. Update the username in `flake.nix` (`username = "user"`).
2. Generate `flake.lock` after Nix is available:
   - run `nix flake lock` from inside `src/`
3. (Optional) add a `dotfiles/` directory for Home Manager to symlink into `$HOME`.

## Notes

- This repo is intentionally modular: add a new machine by adding a folder under `hosts/` and wiring it in `flake.nix`.
- Keep shared logic in `modules/` and reserve host-specific details for `hosts/<name>/`.
