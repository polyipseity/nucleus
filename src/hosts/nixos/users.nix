# nixos/users.nix — Managed user account definition for the NixOS host.
{ username, ... }:
{
  users.users.${username} = {
    # networkmanager: allows the user to manage Wi-Fi/VPN without sudo.
    # wheel: grants sudo access.
    # Source: NixOS users.users option and group membership semantics.
    # https://mynixos.com/nixpkgs/option/users.users
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    isNormalUser = true;
  };
}
