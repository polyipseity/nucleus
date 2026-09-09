# Declares sops.secrets for every entry in the env catalog.
# Imported by both MacBook and NixOS to avoid per-host duplication.
{ pkgs, username, ... }:
let
  catalog = builtins.fromJSON (builtins.readFile ./catalog.json);
  owner = if pkgs.stdenv.hostPlatform.isDarwin then username else "litellm";
in
{
  sops.secrets = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = {
        sopsFile = ../secrets/system.yml;
        inherit owner;
        mode = "0400";
      };
    }) catalog.keys
  );
}
