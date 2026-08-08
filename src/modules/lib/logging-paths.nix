# Per-host log root paths from services.json $logging.
{
  pkgs,
  hostName ? null,
  ...
}:
let
  hostPlatform = import ./host-platform.nix { inherit pkgs; };
  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  hostKey =
    if hostName != null then
      hostName
    else
      hostPlatform.hostFromStdenv;
  hostLogging = servicesJSON."$logging".${hostKey};
in
{
  inherit hostKey;
  logDirTemplate = hostLogging.logDir;
  systemLogDir = hostLogging.systemLogDir;
}
