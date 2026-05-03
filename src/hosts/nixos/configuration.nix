{ pkgs, ... }:
{
  imports = [ ../../modules/core.nix ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];
  services.xserver.videoDrivers = [ "modesetting" ];

  programs.zsh.enable = true;

  users.users.user = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
  };

  system.stateVersion = "24.11";
}
