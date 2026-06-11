# MacBook/base.nix — Fundamental nix-darwin settings for the MacBook host.
{ username, ... }: {
  # Determinate Nix manages the daemon and installation lifecycle itself.
  # Disabling nix-darwin's Nix management avoids activation conflicts.
  nix.enable = false;

  # Allow Nix to use Rosetta for x86_64-darwin binaries on Apple Silicon.
  # Point the daemon at the machines file written by linux-builder.nix so it
  # routes aarch64-linux derivations to the builder VM.
  # WHY builders-use-substitutes: lets the builder VM fetch cached derivations
  # from the binary cache directly instead of routing all bytes through the
  # macOS host, which would be much slower for large NixOS guest builds.
  # Determinate Nix includes /etc/nix/nix.custom.conf from /etc/nix/nix.conf.
  # Manage that file declaratively so builder routing and trusted-user settings
  # are applied even with nix.enable = false.
  environment.etc."nix/nix.custom.conf".text = ''
    builders = @/etc/nix/machines
    builders-use-substitutes = true
    extra-platforms = x86_64-darwin aarch64-darwin
    trusted-users = root ${username}
  '';

  # nix-darwin v5+ requires an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;

  # Override nix-darwin's default EDITOR=nano to prevent it from interfering
  # with home-manager's neovim defaultEditor (which sets $EDITOR and $VISUAL
  # to nvim). Without this, nix-darwin's system-level export can override the
  # home-manager value depending on shell invocation path.
  environment.variables.EDITOR = "nvim";
}
