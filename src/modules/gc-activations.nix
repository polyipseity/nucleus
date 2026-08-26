# Shared nucleus GC application derivations (cross-host).
#
# The three nucleus GC scripts (system log rotation, Nix store GC, weekly
# sweep) are byte-identical across hosts; only the service/timer wrappers
# differ (systemd on NixOS, launchd on macOS).  This module exposes the shared
# writeNucleusShellApplication derivations so both platform activation files
# import them instead of duplicating the definitions (plan item 6).
{ pkgs }:
{
  logGcSystem = pkgs.writeNucleusShellApplication {
    name = "log-gc-system";
    runtimeInputs = [ pkgs.jq ];
    scriptName = "src/scripts/services/log-gc-system";
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
