# nucleus

`nucleus` is a cross-platform declarative environment repository.

It manages:

- Linux system state (NixOS)
- macOS system state (`nix-darwin`)
- Windows native state (WinGet DSC)
- user-level shell/editor preferences (Home Manager)

Contributor policy and invariants live in `AGENTS.md` and `.agents/instructions/*.instructions.md`.

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
# or directly with individual config files
winget configure .\src\hosts\Windows\system.dsc.yml .\src\hosts\Windows\system-packages.dsc.yml
winget configure .\src\hosts\Windows\user.dsc.yml .\src\hosts\Windows\user-env.dsc.yml .\src\hosts\Windows\user-context.dsc.yml
```

## Notes

- Shared logic in `src/modules/`; host-specific in `src/hosts/<Host>/`.
- Tree guides: [`src/README.md`](src/README.md), [`src/users/README.md`](src/users/README.md), [`scripts/README.md`](scripts/README.md).
- Manual one-time steps: host `MANUAL.md` files.
- Bootstrap tool versions: `scripts/bootstrap-versions.env`.
- Test coverage: `tests/COVERAGE.md`.
