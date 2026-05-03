# nucleus

`nucleus` is a cross-platform, declarative environment repository designed to be a **single source of truth** for:

- Linux system state (NixOS)
- macOS system state (`nix-darwin`)
- Windows native state (WinGet DSC)
- user-level shell/editor preferences (Home Manager)

## Repository architecture

```text
nucleus/
├── .sops.yaml
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
│       ├── secrets/
│       │   └── default.nix
│       └── editors/
│           └── default.nix
├── src/secrets/
│   ├── personal-gpg.yml
│   └── personal-ssh.yml
├── src/scripts/
│   └── apply.sh
└── scripts/
    ├── bootstrap-versions.env
    ├── bootstrap.sh
    └── bootstrap.ps1
```

## What each layer does

- `src/modules/core.nix`: shared CLI tools (`git`, `rustup`, `ripgrep`, `fd`, `bottom`, `eza`, `zoxide`)
- `src/hosts/macbook/default.nix`: macOS defaults (keyboard repeat, dock behavior)
- `src/hosts/nixos/configuration.nix`: Linux host/system defaults and hardware baseline
- `src/hosts/windows/configuration.dsc.yaml`: Windows packages/settings/environment via WinGet DSC
- `src/modules/home.nix`: home-level shell/editor/dotfile composition across platforms
- `src/modules/secrets/default.nix`: decrypt/provision activation logic (SSH + GPG imports)
- `src/scripts/apply.sh`: Unix apply script (secrets preflight + OS config); exposed as `nix run ./src#apply`
- `src/hosts/windows/apply.ps1`: Windows apply script (WinGet DSC + secrets provisioning)
- `.sops.yaml`: key policy for repo secrets (global GPG + per-machine age recipients)
- `src/secrets/*.yml`: SOPS-managed encrypted secret files (GPG keys, SSH keys); one file per identity

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

The bootstrap scripts are intentionally minimal: they only install the
dependencies needed to run the rest of the toolchain.

- Unix-like: `scripts/bootstrap.sh` - installs Nix (if absent) and Nix-managed bootstrap tools
- Windows: `scripts/bootstrap.ps1` - installs Git, GnuPG, and SOPS via winget

When you explicitly request apply, bootstrap can delegate to the apply scripts
after installing dependencies.

### Bootstrap version pins

- All bootstrap-managed tool versions and the Nix installer pin live in
    `scripts/bootstrap-versions.env`.
- Update version/hash values there when bumping bootstrap dependencies.

### Workflow

**Unix:**

```bash
# Step 1: install Nix + bootstrap tools
sh scripts/bootstrap.sh

# Step 2: apply configuration (verifies secrets, then runs darwin-rebuild / nixos-rebuild / home-manager)
nix run ./src#apply

# Or do both in one command
sh scripts/bootstrap.sh apply
```

**Windows (Admin PowerShell):**

```powershell
# Step 1: install Git, GnuPG, SOPS via winget
.\scripts\bootstrap.ps1

# Step 2: apply configuration (WinGet DSC + secrets provisioning)
.\src\hosts\windows\apply.ps1

# Or do both in one command
.\scripts\bootstrap.ps1 -Apply
```

### Help

- Unix: `scripts/bootstrap.sh --help`
- Windows: `scripts/bootstrap.ps1 -Help` or `scripts/bootstrap.ps1 -h`
- Windows apply: `src\hosts\windows\apply.ps1 -Help`

## Security model: unlock and promote

- **Global admin identity**: your GPG encryption subkey can always decrypt repo secrets.
- **Machine automation identity**: each machine can decrypt with its host SSH key
    converted to age recipient form.
- **Order of preference**: host SSH key decryption, then GPG keyring fallback.

Global automation identity is intentionally disabled for now. Add it back later
only if a clear operational need appears.

This gives a one-time secure unlock path and then low-friction autonomous updates.

## Initial key setup

1. Identify your encryption-capable GPG subkey fingerprint:
    - `gpg --list-keys --with-colons`
2. Set your fingerprint in `.sops.yaml` (`*primary_gpg`).
3. Add host age recipients in `.sops.yaml` for `macbook`, `nixos`, and `windows`.
4. Edit secrets with SOPS (one file per identity):
    - `sops src/secrets/personal-gpg.yml`
    - `sops src/secrets/personal-ssh.yml`
5. Re-encrypt after key policy updates:
    - `sops updatekeys src/secrets/personal-gpg.yml`
    - `sops updatekeys src/secrets/personal-ssh.yml`

## Onboarding a new physical machine

1. Import your GPG subkey once on the new machine.
2. Run bootstrap (`scripts/bootstrap.sh` or `scripts/bootstrap.ps1`).
3. Extract the machine age recipient from host SSH public key:
   - Unix: `ssh-to-age < /etc/ssh/ssh_host_ed25519.pub`
   - Windows: `ssh-to-age < $env:PROGRAMDATA\ssh\ssh_host_ed25519.pub`
4. Add that age recipient to `.sops.yaml`, then run for each secret file:
   - `sops updatekeys src/secrets/personal-gpg.yml`
   - `sops updatekeys src/secrets/personal-ssh.yml`
5. Commit and push. Future decryptions can use host key automation.

## First-run checklist

1. Update the username in `flake.nix` (`username = "user"`).
2. Generate `flake.lock` after Nix is available:
   - run `nix flake lock` from inside `src/`
3. Fill placeholders in `.sops.yaml` and encrypt each secret file with `sops --encrypt --in-place`.
4. (Optional) add a `dotfiles/` directory for Home Manager to symlink into `$HOME`.

## Notes

- This repo is intentionally modular: add a new machine by adding a folder under `hosts/` and wiring it in `flake.nix`.
- Keep shared logic in `modules/` and reserve host-specific details for `hosts/<name>/`.
