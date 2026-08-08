# host-platform.nix — Host and platform registry helpers.
#
# Host names (MacBook, NixOS, Windows) are primary lookup keys.
# Platform keys (macOS, NixOS, Windows) own implementation flags.
# Host JSON entries reference platform by name only — flags are never on hosts.
{
  pkgs ? null,
}:
let
  registry = builtins.fromJSON (builtins.readFile ../host-platform-registry.json);

  hosts = registry.hosts;

  platforms = registry.platforms;

  hostKeys = builtins.attrNames hosts;

  platformKeys = builtins.attrNames platforms;

  platformForHost =
    host:
    if builtins.hasAttr host hosts then
      hosts.${host}.platform
    else
      builtins.throw "host-platform.nix: unknown host '${host}'";

  hostForPlatform =
    platform:
    let
      matches = builtins.filter (h: hosts.${h}.platform == platform) hostKeys;
    in
    if matches == [ ] then
      builtins.throw "host-platform.nix: no host maps to platform '${platform}'"
    else if builtins.length matches > 1 then
      builtins.throw "host-platform.nix: platform '${platform}' maps to multiple hosts: ${builtins.toString matches}"
    else
      builtins.head matches;

  flagsForPlatform =
    platform:
    if builtins.hasAttr platform platforms then
      platforms.${platform}.flags
    else
      builtins.throw "host-platform.nix: unknown platform '${platform}'";

  flagsForHost = host: flagsForPlatform (platformForHost host);

  platformHasFlag = platform: flag: (flagsForPlatform platform).${flag} or false;

  hostHasFlag = host: flag: platformHasFlag (platformForHost host) flag;

  validateHostPlatformRef =
    host: platform:
    if platformForHost host != platform then
      builtins.throw "host-platform.nix: host '${host}' expects platform '${platformForHost host}', got '${platform}'"
    else
      null;

  hostFromStdenv =
    if pkgs == null then
      builtins.throw "host-platform.nix: hostFromStdenv requires pkgs"
    else if pkgs.stdenv.isDarwin then
      "MacBook"
    else if pkgs.stdenv.isLinux then
      "NixOS"
    else
      builtins.throw "host-platform.nix: unsupported stdenv for hostFromStdenv";

in
{
  inherit
    registry
    hosts
    platforms
    hostKeys
    platformKeys
    platformForHost
    hostForPlatform
    flagsForPlatform
    flagsForHost
    platformHasFlag
    hostHasFlag
    validateHostPlatformRef
    hostFromStdenv
    ;
}
