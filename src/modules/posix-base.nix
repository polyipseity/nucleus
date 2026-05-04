# modules/posix-base.nix — Shared system-layer defaults for POSIX hosts.
# Imported by both nix-darwin and NixOS host entrypoints.
{ ... }:
{
  # Enable the Nix flakes and new nix CLI consistently on both hosts.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  # Enforce baseline Git behavior globally for every local account.
  # Commit/tag signing is required by default, symlinks are enabled, and
  # line-ending handling follows core.autocrlf=auto for cross-platform repos.
  environment.etc."gitconfig".text = ''
    [commit]
      gpgsign = true
    [core]
      autocrlf = auto
      symlinks = true
    [tag]
      gpgsign = true
  '';

  # Ensure zsh is available as a valid login shell system-wide.
  programs.zsh.enable = true;
}
