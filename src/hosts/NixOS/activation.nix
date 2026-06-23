# NixOS/activation.nix — NixOS system activation hooks for the generic Linux host.
#
# All scripts run during nixos-rebuild switch as root.
{ config, lib, ... }: {
  # ---------------------------------------------------------------------------
  # nvimLauncher
  # Creates a deterministic symlink at /etc/nucleus-bin/nvim that
  # vscode-neovim can use (the extension does not expand ${userHome} or ~).
  # Resolves the nvim path from the home-manager profile directory so that no
  # username is hardcoded, matching Home Manager's useUserPackages = true layout.
  # ---------------------------------------------------------------------------
  system.activationScripts.nvimLauncher = lib.mkAfter ''
    _nvim_real="${config.home-manager.users.polyipseity.home.profileDirectory}/bin/nvim"
    if [ -x "$_nvim_real" ]; then
      mkdir -p /etc/nucleus-bin
      ln -sfn "$_nvim_real" /etc/nucleus-bin/nvim
    fi
  '';
}
