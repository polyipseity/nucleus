# modules/posix-user-shell.nix — Shared POSIX user account defaults.
{
  lib,
  pkgs,
  username,
  ...
}:
{
  users.users.${username} = {
    # Home Manager's OS integration derives `home.homeDirectory` from
    # `users.users.<name>.home`. On nix-darwin that value is not always set,
    # so we provide platform-correct defaults to keep HM evaluation stable.
    home = lib.mkDefault (if pkgs.stdenv.isDarwin then "/Users/${username}" else "/home/${username}");

    # Keep zsh as the managed login shell across POSIX hosts.
    shell = pkgs.zsh;
  };
}
