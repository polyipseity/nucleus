{ pkgs, username, ... }:
{
  users.users.${username} = {
    extraGroups = [ "networkmanager" "wheel" ];
    isNormalUser = true;
    shell = pkgs.zsh;
  };
}
