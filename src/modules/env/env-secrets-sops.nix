# Declares sops.secrets for every entry in the env-secrets catalog.
# Imported by both MacBook and NixOS to avoid per-host duplication.
# Splits declarations by sopsSource: system.yml vs users/<username>.yml.
{ pkgs, username, ... }:
let
  secrets = builtins.fromJSON (builtins.readFile ./env-secrets.json);
  owner = if pkgs.stdenv.hostPlatform.isDarwin then username else "litellm";

  # Partition secrets by sopsSource.
  systemSecrets = builtins.filter (s: s.sopsSource == "system") secrets.secrets;
  userSecrets = builtins.filter (s: s.sopsSource == "user") secrets.secrets;

  mkSopsEntry = sopsFile: map (entry: {
    name = entry.name;
    value = {
      inherit sopsFile owner;
      mode = "0400";
    };
  });
in
{
  sops.secrets = builtins.listToAttrs (
    (mkSopsEntry ../secrets/system.yml systemSecrets)
    ++ (mkSopsEntry ../secrets/users + "/${username}.yml" userSecrets)
  );
}
