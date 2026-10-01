# MacBook/base.nix - Fundamental nix-darwin settings for the MacBook host.
{ username, ... }: {
  # Determin manages its own daemon and install lifecycle, so nix-darwin's Nix
  # management would conflict.
  nix.enable = false;

  # Rosetta covers x86_64-darwin binaries on Apple Silicon; the machines file
  # from linux-builder.nix routes aarch64-linux derivations to the builder VM.
  # WHY: builders-use-substitutes lets the VM fetch from the binary cache instead
  # of pulling every byte through the MacBook. Determin includes nix.custom.conf
  # from nix.conf, so the file stays managed even with nix.enable = false.
  # check-suppress:config-method: method 2 (read-only) -- Nix daemon overwrites nix.custom.conf on restart -- a writable symlink would lose managed settings.
  environment.etc."nix/nix.custom.conf".text =
    builtins.replaceStrings [ "__USERNAME__" ] [ username ]
      (builtins.readFile ../../modules/configs/nix/nix.custom.conf);

  # nix-darwin v5+ needs an explicit primary user for single-user tooling.
  system.primaryUser = username;
  system.stateVersion = 4;
}
