# nucleus

`nucleus` is a cross-platform declarative environment repository.

It manages:

- Linux system state (NixOS)
- macOS system state (`nix-darwin`)
- Windows native state (WinGet DSC)
- user-level shell/editor preferences (Home Manager)

Contributor policy and invariants live in `AGENTS.md` and
`.agents/instructions/*.instructions.md`.

## Repository layout

```text
nucleus/
├── src/
│   ├── flake.nix
│   ├── assets/wallpapers/
│   ├── hosts/
│   │   ├── MacBook/
│   │   ├── NixOS/
│   │   └── Windows/
│   ├── modules/
│   ├── scripts/apply.sh
│   └── secrets/
├── tests/
│   ├── nix/
│   ├── scripts/
│   └── windows/
└── scripts/
    ├── bootstrap.sh
    └── bootstrap.ps1
```

## Apply

### macOS

```bash
nix run ./src#apply
# or directly
darwin-rebuild switch --flake ./src#MacBook
```

### NixOS

```bash
nix run ./src#apply
# or directly
sudo nixos-rebuild switch --flake ./src#NixOS
```

### Windows (Admin PowerShell)

```powershell
.\src\hosts\Windows\apply.ps1
# or directly
winget configure .\src\hosts\Windows\system.dsc.yml
winget configure .\src\hosts\Windows\user.dsc.yml
```

## Validate changes

```bash
# Nix syntax/eval
nix-instantiate --parse src/modules/core.nix
nix flake check ./src
```

```powershell
# Windows DSC dry-run checks
winget configure --what-if .\src\hosts\Windows\system.dsc.yml
winget configure --what-if .\src\hosts\Windows\user.dsc.yml
```

## Secrets and wallpapers

- Secrets and wallpaper assets are encrypted with SOPS.
- Managed encrypted inputs live under `src/secrets/` and `src/assets/wallpapers/`.
- Recipient policy lives in `.sops.yaml`.
- When recipients change, rewrap encrypted files with `sops updatekeys`.

## Virtual machines

`nucleus-vm-setup` (script entrypoint: `scripts/vm-setup.sh` / `scripts/vm-setup.ps1`)
provisions guests from `src/modules/VMs.json`.

Use a dry run first:

```bash
nucleus-vm-setup --dry-run
```

Guest converge steps are documented in `~/virtual machines/README.md`.

## Notes

- Shared logic belongs in `src/modules/`; host-specific details belong in `src/hosts/<Host>/`.
- Manual one-time user steps are documented in host `MANUAL.md` files.
- Bootstrap tool versions are pinned in `scripts/bootstrap-versions.env`.
- Test suite coverage map: `tests/COVERAGE.md`.
