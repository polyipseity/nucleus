# tests/integration/service-watchdog-tests.nix — Structural invariant tests for service watchdog.
#
# Validates services.json structure for the watchdog service and flake wiring.
# Implementation-coupled grep assertions against script source text and platform
# config files have been removed — those are now covered by check steps and
# script-level tests.

let
  inherit (import ../lib.nix) assert' containsRegex;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  flakeText = builtins.readFile ../../src/flake.nix;

  parsedServices = builtins.fromJSON servicesJsonText;
  watchdog = parsedServices.service-watchdog;
in
{
  tests = builtins.filter (x: x != null) [
    # --- services.json structural assertions ---
    (assert' (watchdog ? displayName) "service-watchdog must have a displayName")
    (assert' (containsRegex ''services\.schema\.json'' servicesJsonText)
      "services.json must reference services.schema.json")

    # --- Host entries present for all three platforms ---
    (assert' (watchdog.hosts ? MacBook) "service-watchdog must have a MacBook host entry")
    (assert' (watchdog.hosts ? NixOS) "service-watchdog must have a NixOS host entry")
    (assert' (watchdog.hosts ? Windows) "service-watchdog must have a Windows host entry")

    # --- macOS launchctl service name ---
    (assert' (watchdog.hosts.MacBook.type == "launchctl")
      "MacBook watchdog must use launchctl")
    (assert' (watchdog.hosts.MacBook.service == "local.service-watchdog")
      "MacBook watchdog service must be local.service-watchdog")

    # --- NixOS systemctl service name ---
    (assert' (watchdog.hosts.NixOS.type == "systemctl")
      "NixOS watchdog must use systemctl")
    (assert' (watchdog.hosts.NixOS.service == "nucleus-service-watchdog.service")
      "NixOS watchdog service must be nucleus-service-watchdog.service")

    # --- Windows schtask task path ---
    (assert' (watchdog.hosts.Windows.type == "schtask")
      "Windows watchdog must use schtask")
    (assert' (watchdog.hosts.Windows ? taskPath)
      "Windows watchdog must declare a taskPath")

    # --- Flake wiring ---
    (assert' (containsRegex "nucleus-service-watchdog" flakeText)
      "flake.nix must declare nucleus-service-watchdog")
    (assert' (containsRegex ''name = "service-watchdog"'' flakeText)
      "flake.nix must register service-watchdog as a nucleusApp")
  ];
  success = true;
  message = "Service watchdog structural tests passed";
}
