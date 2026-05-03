{ pkgs, username, ... }:
{
  imports = [ ../../modules/core.nix ];

  networking.firewall.enable = true;
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usbhid" "sd_mod" ];
  services.xserver.videoDrivers = [ "modesetting" ];

  programs.zsh.enable = true;

  sops = {
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    gnupg.home = "/home/${username}/.gnupg";
  };

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
  };

  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
  '';

  system.stateVersion = "24.11";
}
