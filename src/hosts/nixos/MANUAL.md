# nixos manual steps

- Review generated hardware config after first install (`nixos-generate-config`) and replace temporary hardware fragments when real device-specific values are available.
- Re-run apply (`nix run ./src#apply`) after any manual hardware migration to verify declarative convergence.

## Remote desktop

- **xrdp**: no manual steps required; the RDP server starts automatically after `apply`. Connect from any RDP client (Windows built-in Remote Desktop, Microsoft Remote Desktop for macOS, Remmina) to port 3389.
- **Chrome Remote Desktop**: not available as a NixOS package. To enable inbound Chrome Remote Desktop access, install Chrome or Chromium, navigate to <https://remotedesktop.google.com/access>, and complete the Linux host setup wizard. The host daemon runs outside of NixOS package management.
- **Parsec**: launch Parsec after first login and sign in to enable hosting. GPU-accelerated hosting requires hardware rendering support (confirm `vkms` or a real GPU is present with `lsmod | grep -E 'vkms|nvidia|amdgpu|i915'`).
