# tests/modules/hermes-agent-tests.nix — Hermes Agent service registry and cross-host parity.
#
# Validates services.json hermes-agent entry per host.
#
# Run with: nix-instantiate --eval tests/modules/hermes-agent-tests.nix

let
  inherit (import ../lib.nix) assert';

  servicesJson = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  hermes = servicesJson.hermes-agent;
  hosts = hermes.hosts;

  # Per-host type/service
  hostTypes = builtins.mapAttrs (_: v: v.type or null) hosts;
  hostServices = builtins.mapAttrs (_: v: v.service or null) hosts;
in
{
  tests = builtins.filter (x: x != null) [
    # --- Behavioral: services.json structure ---
    (assert' (hermes ? displayName) "hermes-agent must have displayName")
    (assert' (hermes.displayName == "Hermes Agent") "hermes-agent displayName must be 'Hermes Agent'")
    (assert' (hermes ? logging) "hermes-agent must have logging config")
    (assert' (hermes.logging.capture == "all") "hermes-agent must capture all logs")

    # --- MacBook: launchd user agent ---
    (assert' (
      hostTypes.MacBook == "macos-launchctl"
    ) "MacBook hermes-agent must be launchctl, got ${hostTypes.MacBook or "null"}")
    (assert' (
      hostServices.MacBook == "org.nix-community.home.hermes-agent"
    ) "MacBook hermes-agent service must be org.nix-community.home.hermes-agent")
    (assert' (hosts.MacBook.scope == "user") "MacBook hermes-agent must be user-scoped")
    (assert' (hosts.MacBook.launchdDomain == "gui") "MacBook hermes-agent must use gui domain")

    # --- NixOS: systemd user service ---
    (assert' (
      hostTypes.NixOS == "nixos-systemctl"
    ) "NixOS hermes-agent must be systemctl, got ${hostTypes.NixOS or "null"}")
    (assert' (
      hostServices.NixOS == "hermes-agent.service"
    ) "NixOS hermes-agent service must be hermes-agent.service")
    (assert' (hosts.NixOS.scope == "user") "NixOS hermes-agent must be user-scoped")

    # --- Windows: SCM native service ---
    (assert' (
      hostTypes.Windows == "windows-native"
    ) "Windows hermes-agent must be native SCM, got ${hostTypes.Windows or "null"}")
    (assert' (
      hostServices.Windows == "hermes-gateway"
    ) "Windows hermes-agent service must be hermes-gateway")
  ];

  success = true;
  message = "Hermes Agent tests passed";
}
