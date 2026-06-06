# nucleus

`nucleus` is a cross-platform declarative environment repository.

It manages:

- Linux system state (NixOS)
- macOS system state (`nix-darwin`)
- Windows native state (WinGet DSC)
- user-level shell/editor preferences (Home Manager)

Contributor policy and invariants live in `AGENTS.md` and
`.agents/instructions/*.instructions.md`.

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

## Notes

- Shared logic belongs in `src/modules/`; host-specific details belong in `src/hosts/<Host>/`.
- Manual one-time user steps are documented in host `MANUAL.md` files.
- Bootstrap tool versions are pinned in `scripts/bootstrap-versions.env`.
- Test suite coverage map: `tests/COVERAGE.md`.
