# Per-host log root paths from services.json $logging.
{
  pkgs,
  hostName ? null,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  hostKey =
    if hostName != null then
      hostName
    else if pkgs.stdenv.isDarwin then
      "MacBook"
    else if pkgs.stdenv.isLinux then
      "NixOS"
    else
      "Windows";
  hostLogging = servicesJSON."$logging".${hostKey};
in
{
  inherit hostKey;
  logDirTemplate = hostLogging.logDir;
  systemLogDir = hostLogging.systemLogDir;
}
