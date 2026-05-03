# macbook/base.nix — Fundamental nix-darwin settings for the MacBook host.
{ username, ... }:
{
  # Allow Nix to use Rosetta for x86_64-darwin binaries on Apple Silicon.
  # Written to nix.conf by nix-darwin, so it applies to all users.
  nix.extraOptions = ''
    extra-platforms = x86_64-darwin aarch64-darwin
  '';

  # nix-darwin v5+ requires an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;
}
