# nixos manual steps

- Review generated hardware config after first install (`nixos-generate-config`) and replace temporary hardware fragments when real device-specific values are available.
- nix-index: run `nix-index` once after first activation to build the file-index database. This is required for pay-respects to suggest `nix profile install` commands when an unknown command is typed. Re-run periodically (e.g. weekly) to keep the index current with nixpkgs updates.
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
