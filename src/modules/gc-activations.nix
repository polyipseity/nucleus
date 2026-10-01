# Shared nucleus GC application derivations (cross-host).
#
# The nucleus GC scripts (log rotation, Nix store GC, weekly sweep) are
# byte-identical across hosts; only the service/timer wrappers differ
# (systemd on NixOS, launchd on macOS).  This module exposes the shared
# writeNucleusShellApplication derivations so both platform activation files
# import them instead of duplicating the definitions (plan item 6).
{ pkgs }:
{
  logGc = pkgs.writeNucleusShellApplication {
    name = "log-gc";
    runtimeInputs = [ pkgs.jq ];
    scriptName = "src/scripts/services/log-gc";
  };

  nixStoreGc = pkgs.writeNucleusShellApplication {
    name = "nix-store-gc";
    runtimeInputs = [ pkgs.nix ];
    scriptName = "src/scripts/services/nix-store-gc";
  };

  gcWeekly = pkgs.writeNucleusShellApplication {
    name = "gc-weekly";
    runtimeInputs = [ ];
    scriptName = "src/scripts/services/gc-sweep";
  };
}
