# Declares sops.secrets for every entry in the env-secrets catalog.
# Imported by both MacBook and NixOS to avoid per-host duplication.
# Splits declarations by sopsSource: system.yml vs users/<username>.yml.
#
# Asserts that SOPS files exist and contain all declared key names.
# Key names are plaintext in SOPS YAML (only values are encrypted),
# so we can parse them at eval time.
{ pkgs, username, ... }:
let
  sopsUtils = import ../lib/sops-utils.nix;
  inherit (sopsUtils) parseSopsKeys missingSopsKeys;

  secrets = builtins.fromJSON (builtins.readFile ./env-secrets.json);
  owner = if pkgs.stdenv.hostPlatform.isDarwin then username else "litellm";

  # Partition secrets by sopsSource.
  systemSecrets = builtins.filter (s: s.sopsSource == "system") secrets.secrets;
  userSecrets = builtins.filter (s: s.sopsSource == "user") secrets.secrets;

  # SOPS file paths.
  systemSopsFile = ../../secrets/system.yml;
  userSopsFile = ../../secrets/users + "/${username}.yml";

  systemSopsKeys = if builtins.pathExists systemSopsFile then parseSopsKeys systemSopsFile else [ ];
  userSopsKeys = if builtins.pathExists userSopsFile then parseSopsKeys userSopsFile else [ ];

  missingSystemKeys = missingSopsKeys systemSopsKeys systemSecrets;
  missingUserKeys = missingSopsKeys userSopsKeys userSecrets;

  mkSopsEntry =
    sopsFile:
    map (entry: {
      name = entry.name;
      value = {
        inherit sopsFile owner;
        mode = "0400";
      };
    });
in
{
  # Assert SOPS files exist when secrets reference them.
  assertions = [
    {
      assertion = builtins.length systemSecrets == 0 || builtins.pathExists systemSopsFile;
      message =
        "env-secrets: ${toString (builtins.length systemSecrets)} secret(s) declared with sopsSource=system "
        + "but SOPS file src/secrets/system.yml does not exist.";
    }
    {
      assertion = builtins.length userSecrets == 0 || builtins.pathExists userSopsFile;
      message =
        "env-secrets: ${toString (builtins.length userSecrets)} secret(s) declared with sopsSource=user "
        + "but SOPS file src/secrets/users/${username}.yml does not exist.";
    }
  ]
  ++ (
    # Assert declared key names exist in the SOPS files.
    if missingSystemKeys != [ ] then
      [
        {
          assertion = false;
          message =
            "env-secrets: keys missing from src/secrets/system.yml: "
            + builtins.concatStringsSep ", " missingSystemKeys;
        }
      ]
    else
      [ ]
  )
  ++ (
    if missingUserKeys != [ ] then
      [
        {
          assertion = false;
          message =
            "env-secrets: keys missing from src/secrets/users/${username}.yml: "
            + builtins.concatStringsSep ", " missingUserKeys;
        }
      ]
    else
      [ ]
  );

  sops.secrets = builtins.listToAttrs (
    (mkSopsEntry systemSopsFile systemSecrets) ++ (mkSopsEntry userSopsFile userSecrets)
  );
}
