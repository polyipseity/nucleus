# nixos/users.nix — Managed user account definition for the NixOS host.
{ pkgs, username, ... }:
{
  users.users.${username} = {
    # networkmanager: allows the user to manage Wi-Fi/VPN without sudo.
    # wheel: grants sudo access.
    extraGroups = [ "networkmanager" "wheel" ];
    isNormalUser = true;
    shell = pkgs.zsh;
  };
}
