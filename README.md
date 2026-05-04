# nucleus

`nucleus` is a cross-platform, declarative environment repository — a single
source of truth for:

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
│   ├── scripts/
│   │   └── apply.sh
│   ├── assets/
│   │   └── wallpapers/  *.sops
│   ├── secrets/
│   │   ├── gpg-personal.yml
│   │   └── ssh-personal.yml
│   ├── hosts/
│   │   ├── macbook/   (activation, base, defaults, homebrew, manual-installations, networking, security, sops)
│   │   ├── nixos/     (base, hardware, networking, security, sops, users)
│   │   └── windows/
│   │       ├── apply.ps1
│   │       ├── system.dsc.yml
│   │       └── user.dsc.yml
│   └── modules/
│       ├── core.nix
│       ├── editors.nix
│       ├── gnupg.nix
│       ├── home.nix
│       ├── linux.nix
│       ├── macos.nix
│       ├── posix-base.nix
│       ├── posix-security.nix
│       ├── posix-sops.nix
│       ├── posix-user-shell.nix
│       ├── secrets.nix
│       ├── shell.nix
│       ├── wallpapers.nix
│       └── windows/
│           ├── common.ps1
│           ├── secrets.ps1
│           └── wallpapers.ps1
└── scripts/
    ├── bootstrap-versions.env
    ├── bootstrap.sh
    └── bootstrap.ps1
```

## What each layer does

| File / module                                | Purpose                                                                                                                                                                                       |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/modules/core.nix`                       | Shared CLI packages (`bat`, `bottom`, `direnv`, `eza`, `fd`, `fzf`, `git`, `gnupg`, `jq`, `opencode`, `ripgrep`, `rustup`, `sops`, `uv`, `zoxide`) plus the macOS `overlappingPackages` table |
| `src/modules/gnupg.nix`                      | nix-darwin GnuPG agent (option-presence-guarded; imported by both POSIX hosts)                                                                                                                |
| `src/modules/home.nix`                       | Home Manager entrypoint; imports all feature modules                                                                                                                                          |
| `src/modules/editors.nix`                    | VS Code settings and extension management across platforms                                                                                                                                    |
| `src/modules/linux.nix`                      | GNOME/dconf parity settings for NixOS Home Manager sessions                                                                                                                                   |
| `src/modules/macos.nix`                      | macOS activation hooks, display/session tuning, launch-services handlers, user-session hardening                                                                                              |
| `src/modules/posix-base.nix`                 | Shared system-layer defaults (flakes experimental feature, system zsh) for both POSIX hosts                                                                                                   |
| `src/modules/posix-security.nix`             | Shared sudo timeout hardening (`timestamp_timeout=5`)                                                                                                                                         |
| `src/modules/posix-sops.nix`                 | Shared SOPS key sources: SSH host key age recipient + GnuPG home fallback                                                                                                                     |
| `src/modules/posix-user-shell.nix`           | Shared user account defaults (platform-correct home dir, zsh login shell)                                                                                                                     |
| `src/modules/secrets.nix`                    | Declarative SSH/GPG secret provisioning via Home Manager activation                                                                                                                           |
| `src/modules/shell.nix`                      | Zsh with plugins, direnv + nix-direnv, zoxide, shell aliases                                                                                                                                  |
| `src/modules/wallpapers.nix`                 | Decrypts wallpaper blobs to `~/Pictures/wallpapers`; applies rotating gallery                                                                                                                 |
| `src/modules/windows/common.ps1`             | Executable resolution, SOPS decryption helpers, WinGet DSC invocation                                                                                                                         |
| `src/modules/windows/secrets.ps1`            | Batch and JIT secret/key materialization                                                                                                                                                      |
| `src/modules/windows/wallpapers.ps1`         | Wallpaper materialization on Windows                                                                                                                                                          |
| `src/hosts/macbook/default.nix`              | nix-darwin entrypoint; imports all macbook fragments + shared posix modules                                                                                                                   |
| `src/hosts/macbook/manual-installations.nix` | Imperative installers for software not in nixpkgs or Homebrew                                                                                                                                 |
| `src/hosts/nixos/default.nix`                | NixOS entrypoint; imports all nixos fragments + shared posix modules                                                                                                                          |
| `src/hosts/windows/system.dsc.yml`           | Pre-provision Windows baseline: packages + machine settings                                                                                                                                   |
| `src/hosts/windows/user.dsc.yml`             | Post-provision Windows baseline: folders + user settings                                                                                                                                      |
| `src/scripts/apply.sh`                       | OS-detecting apply dispatcher (wrapped as `nix run .#apply`)                                                                                                                                  |
| `src/hosts/windows/apply.ps1`                | Thin Windows apply wrapper; invokes WinGet DSC                                                                                                                                                |
| `src/assets/wallpapers/*.sops`               | Encrypted wallpaper blobs                                                                                                                                                                     |
| `.sops.yaml`                                 | Key policy: global GPG + per-machine age recipients                                                                                                                                           |
| `src/secrets/*.yml`                          | SOPS-encrypted identities (GPG keys, SSH keys)                                                                                                                                                |

## Apply commands

### macOS

```bash
nix run ./src#apply
# or directly:
darwin-rebuild switch --flake ./src#macbook
```

### Linux (NixOS)

```bash
nix run ./src#apply
# or directly:
sudo nixos-rebuild switch --flake ./src#nixos
```

### Windows (Admin PowerShell)

```powershell
.\src\hosts\windows\apply.ps1
# or directly:
winget configure .\src\hosts\windows\system.dsc.yml
winget configure .\src\hosts\windows\user.dsc.yml
```

## Engine-first apply pattern

Both apply entrypoints (`src/scripts/apply.sh` and `src/hosts/windows/apply.ps1`)
follow the same minimal orchestration:

1. Load environment/module context.
2. Execute the declarative engine (`nix` or `winget configure`).

Pre-flight checks, secret materialization, and gallery refresh live in the
declarative layers — not in the orchestration scripts:

- Unix/macOS: Home Manager activation hooks in `secrets.nix` and `wallpapers.nix`.
- Windows: WinGet DSC resources in `src/hosts/windows/*.dsc.yml`; PowerShell
  module helpers provide JIT secret materialization when needed.

## Security model

- **Global admin identity**: your GPG encryption subkey can always decrypt repo secrets.
- **Machine automation identity**: each host decrypts with its SSH host key
  converted to an age recipient.
- **Precedence**: host SSH key first, then GPG keyring fallback.

Global automation identity is intentionally disabled. Re-enable only if a clear
operational need arises.

## Wallpaper workflow

Encrypted images live under `src/assets/wallpapers/` as individual `.sops` blobs.

Encrypt an image:

```bash
sops --encrypt --input-type binary --output src/assets/wallpapers/aurora.jpg.sops /path/to/aurora.jpg
```

Apply-time materialization:

- **Unix/macOS**: Home Manager activation (`wallpapers.nix`) decrypts all blobs
  to `~/Pictures/wallpapers/`, deletes stale files with no matching `.sops`
  source, then applies the rotating gallery (folder on macOS; XML on GNOME).
- **Windows**: JIT decryption via `src/modules/windows/wallpapers.ps1`.

Naming: `<original-name>.<ext>.sops` (e.g. `aurora.jpg.sops`). Keep plaintext
images out of the repository after encryption.

`src/assets/wallpapers/*.sops` is marked `binary` in `.gitattributes` to
prevent line-ending transforms and text diff heuristics.

## Adding a new machine

1. Import your GPG subkey on the new machine.
2. Run bootstrap if Nix / WinGet prerequisites are not yet installed:
   - Unix: `sh scripts/bootstrap.sh`
   - Windows (Admin): `.\scripts\bootstrap.ps1`
3. Extract the machine's age recipient from its SSH host public key:
   - Unix: `ssh-to-age < /etc/ssh/ssh_host_ed25519.pub`
   - Windows: `ssh-to-age < $env:PROGRAMDATA\ssh\ssh_host_ed25519.pub`
4. Add that recipient to `.sops.yaml`, then re-encrypt each secret file:

   ```bash
   sops updatekeys src/secrets/gpg-personal.yml
   sops updatekeys src/secrets/ssh-personal.yml
   ```

5. Commit and push. Future decryptions use the host key automatically.

## Notes

- Add a new POSIX host by creating a directory under `src/hosts/` and wiring it
  in `src/flake.nix`.
- Keep shared logic in `src/modules/` and reserve host-specific details for
  `src/hosts/<name>/`.
- `scripts/bootstrap-versions.env` pins all bootstrap tool versions. Update it
  when bumping bootstrap dependencies.
- `tests/` is a placeholder; test infrastructure has not been added yet.
