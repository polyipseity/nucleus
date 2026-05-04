# modules/git.nix — Per-user Git identity mapping and shared Git behavior.
{ config, lib, ... }:
let
  # Mapping table keyed by Home Manager username so adding another profile is a
  # data-only change that does not require editing logic.
  gitIdentityByUsername = {
    polyipseity = {
      email = "polyipseity@gmail.com";
      name = "William So";
      # Use the dedicated signing subkey and suffix `!` so Git/GnuPG do not
      # auto-select a different key from the same primary key hierarchy.
      signingKey = "307DBE2F09912754!";
    };
  };

  hasMappedIdentity = builtins.hasAttr config.home.username gitIdentityByUsername;
  selectedIdentity =
    if hasMappedIdentity then
      gitIdentityByUsername.${config.home.username}
    else
      null;
  # Enforce explicit per-user signing key declaration for every mapped user so
  # commit signing identity cannot silently fall back to GnuPG key auto-pick.
  hasExplicitSigningKey = hasMappedIdentity && selectedIdentity ? signingKey && selectedIdentity.signingKey != "";
in
{
  assertions = lib.optionals hasMappedIdentity [
    {
      assertion = hasExplicitSigningKey;
      message = "modules/git.nix: mapped user `${config.home.username}` must define `signingKey` in gitIdentityByUsername.";
    }
  ];

  programs.git = {
    enable = true;
    # Pin signing format explicitly because the Home Manager default changed in
    # 25.05; this keeps OpenPGP signing behavior stable across state versions.
    signing = {
      format = "openpgp";
      key = lib.mkIf hasMappedIdentity selectedIdentity.signingKey;
    };
    settings =
      {
        # Rewrite GitHub HTTPS remotes to SSH globally for this user so clones
        # and future remotes authenticate with the SSH identity automatically.
        url."git@github.com:".insteadOf = "https://github.com/";
      }
      // lib.optionalAttrs hasMappedIdentity {
        user = {
          email = selectedIdentity.email;
          name = selectedIdentity.name;
        };
      };
  };
}
