{ pkgs, ... }:
{
  imports = [ ../../modules/core.nix ];

  networking.hostName = "workstation";
  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];
  services.xserver.videoDrivers = [ "modesetting" ];

  programs.zsh.enable = true;

  users.users.user = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.zsh;
  };

  system.stateVersion = "24.11";
}
