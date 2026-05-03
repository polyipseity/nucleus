# modules/posix-user-shell.nix — Shared login shell assignment for POSIX hosts.
{ pkgs, username, ... }:
{
  users.users.${username}.shell = pkgs.zsh;
}
