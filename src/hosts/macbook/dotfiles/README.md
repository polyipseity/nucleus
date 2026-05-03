# MacBook IaC

This repository defines one macOS host with `nix-darwin`, `home-manager`, and Homebrew.
It is designed for repeatable rebuilds: machine settings, CLI tools, and GUI apps are all declared in code.

## file map

- `flake.nix`: Flake entry point. Pins upstream inputs and exports `darwinConfigurations.MacBook`.
- `configuration.nix`: Main host module. Declares macOS defaults, users, packages, casks, and Neovim config.
- `setup.sh`: Bootstrap script for first install and rebuild orchestration.

## architecture notes

- `flake.nix` computes `currentUserName` from `SUDO_USER` first, then `USER`.
- `flake.nix` passes `currentUserName`, `hostName`, and `userList` into `configuration.nix` through `specialArgs`.
- `configuration.nix` creates a Home Manager profile for each entry in `userList`.
- Secret symlinks and GPG import are scoped to the primary user only.

## prerequisites

- macOS on Apple Silicon (this config sets `nixpkgs.hostPlatform = "aarch64-darwin"`)
- sudo access
- network access for Homebrew and Determinate Nix installers

The script looks for config in this order:
1. The directory containing `setup.sh` (if `flake.nix` and `configuration.nix` are also there)
2. `~/Library/Mobile Documents/com~apple~CloudDocs/dotfiles`

## expected secrets

`configuration.nix` links secrets from `${iCloudRoot}/dotfiles/secrets` for the primary user.
Expected files:

- `id_rsa`
- `id_rsa.pub`
- `gnupg.asc`

If those files are missing, rebuild still completes. Key import is guarded and non-fatal.

## first bootstrap

```bash
chmod +x setup.sh
./setup.sh
```

What `setup.sh` does:

1. Confirms macOS and requests sudo once.
2. Starts a sudo keep-alive background loop and cleans it up on exit.
3. Ensures `/nix` exists.
   - If missing, writes `nix` into `/etc/synthetic.conf`, then exits and asks for reboot.
4. Installs Homebrew if missing and appends shell init to `~/.zprofile`.
5. Installs Determinate Nix if missing and appends shell init to `~/.zshrc`.
6. Copies `flake.nix` and `configuration.nix` into `/etc/nix-darwin`.
7. Syncs `files/` into `/etc/nix-darwin/files` so flake-relative assets resolve.
8. Runs:

```bash
sudo -E HOME=/var/root nix run nix-darwin -- switch --flake .#MacBook --impure --option accept-flake-config true
```

## normal rebuild workflow

After editing `configuration.nix` or `flake.nix`, rebuild with:

```bash
sudo -E nix run nix-darwin -- switch --flake /etc/nix-darwin#MacBook --impure
```

`--impure` is required because `flake.nix` resolves user context from environment variables (`SUDO_USER` / `USER`).

If you changed files under your dotfiles directory, refresh `/etc/nix-darwin` first:

```bash
sudo install -m 0644 ./flake.nix /etc/nix-darwin/flake.nix
sudo install -m 0644 ./configuration.nix /etc/nix-darwin/configuration.nix
```

## common customizations

- Add CLI tools in `environment.systemPackages` (`configuration.nix`)
- Add/remove GUI apps in `managedCasks` (`configuration.nix`)
- Change host name by updating `hostName` (`flake.nix`)
- Manage additional users by expanding `userList` (`flake.nix`)

## troubleshooting

`/nix` is still missing after setup attempt:
- Reboot once after `setup.sh` writes to `/etc/synthetic.conf`.
- Re-run `./setup.sh`.

Nix command not found after install:
- Open a new shell session, then run:
  `source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`

Flake cannot determine current user:
- Run through `setup.sh` (preferred), or export `USER` before running `nix` manually.

Homebrew command not found in current shell:
- Run:
  `eval "$(/opt/homebrew/bin/brew shellenv)"`

Key import did not occur:
- Verify `gnupg.asc` exists in the expected `secrets` directory.
- Rebuild again after fixing the file path.
