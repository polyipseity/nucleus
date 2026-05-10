# nixos manual steps

- Review generated hardware config after first install (`nixos-generate-config`) and replace temporary hardware fragments when real device-specific values are available.
- Re-run apply (`nix run ./src#apply`) after any manual hardware migration to verify declarative convergence.

## Remote desktop

- **xrdp**: no manual steps required; the RDP server starts automatically after `apply`. Connect from any RDP client (Windows built-in Remote Desktop, Microsoft Remote Desktop for macOS, Remmina) to port 3389.
- **Chrome Remote Desktop**: not available as a NixOS package. To enable inbound Chrome Remote Desktop access, install Chrome or Chromium, navigate to <https://remotedesktop.google.com/access>, and complete the Linux host setup wizard. The host daemon runs outside of NixOS package management.
- **Parsec**: launch Parsec after first login and sign in to enable hosting. GPU-accelerated hosting requires hardware rendering support (confirm `vkms` or a real GPU is present with `lsmod | grep -E 'vkms|nvidia|amdgpu|i915'`).

## Wake-on-LAN

Wake-on-LAN (WoL) cannot be declared in Nix without knowing the interface name,
which is hardware-specific. Once the primary wired interface name is known,
move this to a declarative option in `src/hosts/nixos/networking.nix` and
remove this section.

1. Find the primary wired interface name:

   ```sh
   ip -o link show | awk '/ether/ {print $2}' | tr -d ':'
   ```

2. Enable WoL for the current boot (replace `<iface>` with the name from step 1):

   ```sh
   sudo ethtool -s <iface> wol g
   ```

3. Make it permanent by adding to `src/hosts/nixos/networking.nix`:

   ```nix
   networking.interfaces."<iface>".wakeOnLan.enable = true;
   ```

   Then re-run `nix run ./src#apply` and commit the change.

## Shell aliases (full reference)

These aliases are managed declaratively and are available in both zsh and PowerShell profiles.

| Alias | Full form | Description |
| --- | --- | --- |
| `g` | `git` | Run Git directly with full argument passthrough. |
| `ga` | `git add` | Stage files/changes. |
| `gc` | `git commit` | Create a commit. |
| `gca` | `git commit --amend` | Amend the most recent commit. |
| `gco` | `git checkout` | Switch branches or restore paths. |
| `gd` | `git diff` | Show working tree/staged diffs. |
| `gl` | `git log --oneline --decorate --graph` | Compact decorated commit graph. |
| `gp` | `git push` | Push refs to remote. |
| `gpl` | `git pull` | Pull/fetch and integrate upstream changes. |
| `gs` | `git status -sb` | Short branch-aware Git status. |
| `gst` | `git status` | Full Git status output. |
| `la` | `eza -la` | Detailed all-files directory listing. |
| `ll` | `eza -la` | Same as `la` for muscle-memory parity. |
| `ni` | `bun install` | Install Bun project dependencies. |
| `nr` | `bun run` | Run Bun project scripts. |
| `nucleus-gc` | `nix run ./src#gc` | Run repository garbage-collection workflow. |
| `nucleus-health-check` | `nix run ./src#health-check` | Run repository health checks. |
| `nucleus-update` | `nix run ./src#update` | Run repository update workflow. |
| `nx` | `bun x` | Run one-off Bun package executables (`npx`-style). |
| `v` | `nvim` | Open Neovim. |
