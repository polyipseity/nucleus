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
│   │   ├── git-identities.yml
│   │   ├── gpg-personal.yml
│   │   └── ssh-personal.yml
│   ├── hosts/
│   │   ├── macbook/   (MANUAL, activation, base, defaults, homebrew, manual-installations, networking, security, sops)
│   │   ├── nixos/     (MANUAL, base, hardware/{cpu,disks,gpu}, networking, security, sops, users)
│   │   └── windows/
│   │       ├── apply.ps1
│   │       ├── system.dsc.yml
│   │       └── user.dsc.yml
│   └── modules/
│       ├── configs/
│       │   └── vscode-settings.json
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
│       ├── shell/
│       │   ├── aliases.nix
│       │   └── env.nix
│       ├── wallpapers.nix
│       └── windows/
│           ├── convert-sshpublickeytoage.ps1
│           ├── get-nucleusdecryptedblob.ps1
│           ├── get-nucleussecrets.ps1
│           ├── git-ssh.ps1
│           ├── invoke-nucleusjitsecretmaterialization.ps1
│           ├── invoke-nucleussecretverification.ps1
│           ├── invoke-nucleuswingetconfiguration.ps1
│           ├── power.ps1
│           ├── rdp.ps1
│           ├── register-nucleushostagekey.ps1
│           ├── remote-access.ps1
│           ├── remove-nucleusmanagedsecrets.ps1
│           ├── remove-nucleusstalewallpapers.ps1
│           ├── resolve-nucleusexecutable.ps1
│           ├── shell.ps1
│           ├── sync-nucleussecretfile.ps1
│           ├── sync-nucleussecrets.ps1
│           ├── sync-nucleusvscodeextensions.ps1
│           ├── sync-nucleusvscodesettings.ps1
│           ├── sync-nucleuswallpapers.ps1
│           ├── test-nucleusprimaryuser.ps1
│           └── verify-archiving-stack.ps1
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
| `src/modules/editors.nix`                    | VS Code settings/extension management and backend parity wiring across platforms                                                                                                              |
| `src/modules/linux.nix`                      | GNOME/dconf parity settings for NixOS Home Manager sessions                                                                                                                                   |
| `src/modules/macos.nix`                      | macOS activation hooks, display/session tuning, launch-services handlers, user-session hardening                                                                                              |
| `src/modules/posix-base.nix`                 | Shared system-layer defaults (flakes experimental feature, system zsh) for both POSIX hosts                                                                                                   |
| `src/modules/posix-security.nix`             | Shared sudo timeout hardening (`timestamp_timeout=5`)                                                                                                                                         |
| `src/modules/posix-sops.nix`                 | Shared SOPS key sources: machine SSH key age recipient + GnuPG home fallback                                                                                                                  |
| `src/modules/posix-user-shell.nix`           | Shared user account defaults (platform-correct home dir, zsh login shell)                                                                                                                     |
| `src/modules/secrets.nix`                    | Declarative SSH/GPG secret provisioning via Home Manager activation                                                                                                                           |
| `src/modules/shell.nix`                      | Shared shell feature wiring (zsh, direnv, zoxide)                                                                                                                                             |
| `src/modules/shell/aliases.nix`              | Shared shell aliases (strict alphabetical keys)                                                                                                                                                |
| `src/modules/shell/env.nix`                  | Shared shell environment variable attrset (strict alphabetical keys)                                                                                                                           |
| `src/modules/wallpapers.nix`                 | Decrypts wallpaper blobs to `~/Pictures/wallpapers`; applies rotating gallery                                                                                                                 |
| `src/modules/windows/resolve-nucleusexecutable.ps1` | WinGet/SOPS/GPG executable path resolution                                                                                                                                                     |
| `src/modules/windows/convert-sshpublickeytoage.ps1` | Pure-PowerShell SSH Ed25519 → age bech32 public key conversion (shared by verification and registration)                                                                                      |
| `src/modules/windows/get-nucleussecrets.ps1` | Structured secret decryption (`machine SSH -> GPG -> primary SSH`)                                                                                                                            |
| `src/modules/windows/register-nucleushostagekey.ps1` | Machine age key auto-registration: inserts SSH host key into `.sops.yaml` and rewraps SOPS files                                                                                              |
| `src/modules/windows/sync-nucleussecrets.ps1` | Batch secret/key materialization entrypoint                                                                                                                                                    |
| `src/modules/windows/sync-nucleuswallpapers.ps1` | Wallpaper blob materialization on Windows                                                                                                                                                      |
| `src/hosts/macbook/default.nix`              | nix-darwin entrypoint; imports all macbook fragments + shared posix modules                                                                                                                   |
| `src/hosts/macbook/MANUAL.md`                | One-time manual macOS steps printed at activation tail                                                                                                                                        |
| `src/hosts/macbook/manual-installations.nix` | Imperative installers for software not in nixpkgs or Homebrew                                                                                                                                 |
| `src/hosts/nixos/default.nix`                | NixOS entrypoint; imports all nixos fragments + shared posix modules                                                                                                                          |
| `src/hosts/nixos/MANUAL.md`                  | One-time manual NixOS steps printed at activation tail                                                                                                                                        |
| `src/hosts/windows/system.dsc.yml`           | Pre-provision Windows baseline: packages + machine settings                                                                                                                                   |
| `src/hosts/windows/user.dsc.yml`             | Post-provision Windows baseline: folders + user settings                                                                                                                                      |
| `src/scripts/apply.sh`                       | OS-detecting apply dispatcher (wrapped as `nix run .#apply`)                                                                                                                                  |
| `src/hosts/windows/apply.ps1`                | Thin Windows apply wrapper; invokes WinGet DSC                                                                                                                                                |
| `src/assets/wallpapers/*.sops`               | Encrypted wallpaper blobs                                                                                                                                                                     |
| `.sops.yaml`                                 | Key policy: shared age recipient list (`keys.age_devices`) + global GPG backup recipient                                                                                                     |
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
- **Machine automation identities**: each physical machine contributes one age
  recipient derived from that machine's SSH host key.
- **Primary SSH backup identity**: your primary personal SSH key is the final
  entry in `keys.age_devices` and acts as the last age-recipient fallback.
- **Recipient scope**: age recipients are shared across hosts and files; do not
  partition recipients by host class.
- **Precedence**: machine SSH key first, then GPG keyring fallback, then
  primary SSH key fallback.

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
- **Windows**: JIT decryption via `src/modules/windows/sync-nucleuswallpapers.ps1`.

Naming: `<original-name>.<ext>.sops` (e.g. `aurora.jpg.sops`). Keep plaintext
images out of the repository after encryption.

## Managing machine recipients

Use one age recipient per physical machine and keep all real recipients in
`.sops.yaml` `keys.age_devices`, with your primary personal SSH recipient as the
final fallback entry. Keep `keys.primary_gpg` as the global GPG backup
recipient.

### Add a machine

1. Run bootstrap if Nix / WinGet prerequisites are not yet installed:
   - Unix: `sh scripts/bootstrap.sh`
   - Windows (Admin): `.\scripts\bootstrap.ps1`
2. Import your GPG private key on the new machine so `sops updatekeys` can
   re-encrypt secrets for the new machine age recipient:
   ```bash
   gpg --import <backup-key-file>
   ```
3. Run apply — machine age key registration is automatic:
   - Unix: `./scripts/bootstrap.sh apply` (or `nix run ./src#apply`)
   - Windows (Admin): `.\src\hosts\windows\apply.ps1`

   `apply` derives the machine age public key from the SSH host key, inserts it
   into `.sops.yaml`, and rewraps every encrypted file in one step.  It prints
   the git commands to run afterward but does not commit automatically.
4. Commit and push the updated `.sops.yaml` and rewrapped secrets so other
   machines can verify the new recipient:
   ```bash
   git add .sops.yaml src/secrets src/assets/wallpapers
   git commit -m "chore: register <hostname> machine age key"
   git push
   ```

### Remove a machine

1. Delete the machine's recipient from `.sops.yaml` `keys.age_devices`.
2. Rewrap all encrypted files so removed recipients lose access:

   ```bash
   sops updatekeys src/secrets/git-identities.yml
   sops updatekeys src/secrets/gpg-personal.yml
   sops updatekeys src/secrets/ssh-personal.yml
   for f in src/assets/wallpapers/*.sops; do
     [ -e "$f" ] || continue
     sops updatekeys "$f"
   done
   ```

3. Commit and push.

## Notes

- Add a new POSIX host by creating a directory under `src/hosts/` and wiring it
  in `src/flake.nix`.
- Keep shared logic in `src/modules/` and reserve host-specific details for
  `src/hosts/<name>/`.
- `scripts/bootstrap-versions.env` pins all bootstrap tool versions. Update it
  when bumping bootstrap dependencies.
- `tests/` is a placeholder; test infrastructure has not been added yet.
