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
│   │   │   ├── activation.nix
│   │   │   ├── base.nix
│   │   │   ├── default.nix
│   │   │   ├── defaults.nix
│   │   │   ├── homebrew.nix
│   │   │   ├── networking.nix
│   │   │   ├── security.nix
│   │   │   └── sops.nix
│   │   ├── nixos/
│   │   │   ├── base.nix
│   │   │   ├── default.nix
│   │   │   ├── hardware.nix
│   │   │   ├── networking.nix
│   │   │   ├── security.nix
│   │   │   ├── sops.nix
│   │   │   └── users.nix
│   │   └── windows/
│   │       ├── apply.ps1
│   │       ├── system.dsc.yml
│   │       └── user.dsc.yml
│   └── modules/
│       ├── core.nix
│       ├── editors.nix
│       ├── home.nix
│       ├── macos.nix
│       ├── secrets.nix
│       ├── shell.nix
│       ├── wallpapers.nix
│       └── windows/
│           ├── common.ps1
│           ├── secrets.ps1
│           └── wallpapers.ps1
├── src/assets/
│   └── wallpapers/
│       └── *.sops
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

- `src/modules/core.nix`: shared CLI tools (`bat`, `bottom`, `direnv`, `eza`, `fd`, `fzf`, `git`, `gnupg`, `jq`, `ripgrep`, `rustup`, `sops`, `uv`, `zoxide`) plus macOS-only desktop helpers
- `src/hosts/macbook/default.nix`: macOS host entrypoint importing focused host modules (`activation.nix`, `homebrew.nix`, `defaults.nix`, etc.) for easier future extension
- `src/hosts/nixos/default.nix`: NixOS host entrypoint importing focused host modules (`hardware.nix`, `users.nix`, `security.nix`, etc.) for easier future extension
- `src/hosts/windows/system.dsc.yml`: Windows pre-provision baseline via WinGet DSC (packages + machine settings)
- `src/hosts/windows/user.dsc.yml`: Windows post-provision baseline via WinGet DSC (folders + user settings)
- `src/modules/home.nix`: home-level shell/editor/dotfile composition across platforms
- `src/modules/macos.nix`: macOS Home Manager activation workflows (display/session tuning, launch-services app handlers, and user-session hardening)
- `src/modules/secrets.nix`: declarative secret provisioning activation logic (SSH + GPG imports)
- `src/modules/shell.nix`: declarative shell aliases and environment tooling integration
- `src/modules/wallpapers.nix`: declarative wallpaper materialization to `~/Pictures/wallpapers`
- `src/modules/windows/common.ps1`: Windows helper module for executable resolution, SOPS decryption helpers, and WinGet DSC invocation
- `src/modules/windows/secrets.ps1`: Windows helper module for batch and JIT secrets/key materialization entrypoints
- `src/modules/windows/wallpapers.ps1`: Windows helper module for wallpaper materialization
- `src/scripts/apply.sh`: thin Unix apply wrapper that loads environment context and executes the Nix engine (`nix` rebuild/switch)
- `src/hosts/windows/apply.ps1`: thin Windows apply wrapper that loads shared module context and executes the WinGet DSC engine (`winget configure`)
- `src/assets/wallpapers/*.sops`: encrypted wallpaper blobs materialized to `~/Pictures/wallpapers`
- `.sops.yaml`: key policy for repo secrets (global GPG + per-machine age recipients)
- `src/secrets/*.yml`: SOPS-managed encrypted secret files (GPG keys, SSH keys); one file per identity

### Engine-first apply pattern

Both primary apply entrypoints (`src/scripts/apply.sh` and
`src/hosts/windows/apply.ps1`) use the same minimal orchestration pattern:

1. **Load environment/module context**.
2. **Execute declarative engine** (`nix` or `winget configure`).

Pre-flight checks, secret materialization, and refresh behavior live in
declarative layers:

- Unix/macOS: Home Manager activation hooks in `src/modules/secrets.nix` and
    `src/modules/wallpapers.nix`.
- Windows: WinGet DSC resources in `src/hosts/windows/*.dsc.yml`, with module
    helpers providing JIT secret materialization entrypoints when needed.

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
winget configure .\src\hosts\windows\system.dsc.yml
winget configure .\src\hosts\windows\user.dsc.yml
```

## Bootstrap scripts

The bootstrap scripts are intentionally minimal: they only install the
dependencies needed to run the rest of the toolchain.

- Unix-like: `scripts/bootstrap.sh` - installs Nix (if absent) and Nix-managed bootstrap tools, with macOS `/nix` preflight handling
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

# Step 2: apply configuration (declarative secret/wallpaper provisioning runs via Home Manager activation)
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

## Binary wallpaper workflow (large collections)

For large wallpaper sets (10+ files), store each encrypted image as an
individual `.sops` blob under `src/assets/wallpapers/`.

- Recommended naming: `<original-name>.<ext>.sops` (for example: `aurora.jpg.sops`)
- Keep plaintext images out of the repository after encryption
- Avoid frequent re-encryption churn; each blob change stores a full binary in Git history

Encrypt a wallpaper file:

```bash
sops --encrypt --input-type binary --output src/assets/wallpapers/aurora.jpg.sops /path/to/aurora.jpg
```

Apply-time materialization:

- Unix/macOS: Home Manager activation (`src/modules/wallpapers.nix`) decrypts all `*.sops` blobs to `$HOME/Pictures/wallpapers/<name>.<ext>` and runs desktop refresh hooks.
- Windows: user-state application is declarative through WinGet DSC (`src/hosts/windows/user.dsc.yml`), with refresh ordering expressed through DSC `dependsOn` and module-based JIT secret materialization available for resource-level consumers.

Git handling:

- `src/assets/wallpapers/*.sops` is marked as `binary` in `.gitattributes`
- This prevents line-ending transforms and text diff heuristics on encrypted blobs

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
4. (Optional) add `src/dotfiles/.config` and/or `src/dotfiles/.gitconfig` for Home Manager-managed symlinks.

## Notes

- This repo is intentionally modular: add a new machine by adding a folder under `hosts/` and wiring it in `flake.nix`.
- Keep shared logic in `modules/` and reserve host-specific details for `hosts/<name>/`.
