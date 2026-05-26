# MacBook/base.nix — Fundamental nix-darwin settings for the MacBook host.
{ username, ... }:
{
  # Determinate Nix manages the daemon and installation lifecycle itself.
  # Disabling nix-darwin's Nix management avoids activation conflicts.
  nix.enable = false;

  # Allow Nix to use Rosetta for x86_64-darwin binaries on Apple Silicon.
  # Point the daemon at the machines file written by linux-builder.nix so it
  # routes aarch64-linux derivations to the builder VM.
  # WHY builders-use-substitutes: lets the builder VM fetch cached derivations
  # from the binary cache directly instead of routing all bytes through the
  # macOS host, which would be much slower for large NixOS guest builds.
  # WHY nix.extraOptions instead of nix.settings: nix.settings is only written
  # to nix.conf when nix.enable = true; extraOptions is always appended so
  # Determinate Nix picks up these settings via its own nix.conf management.
  nix.extraOptions = ''
    builders = @/etc/nix/machines
    builders-use-substitutes = true
    extra-platforms = x86_64-darwin aarch64-darwin
  '';

  # nix-darwin v5+ requires an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;
}
