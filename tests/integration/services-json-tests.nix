# tests/integration/services-json-tests.nix — Structural invariant tests for service management.
#
# Validates services.json data integrity: schema reference, required services,
# host validity, scope correctness, per-user justification, and watchdog wiring.
#
# Run with: nix-instantiate --eval tests/integration/services-json-tests.nix

let
  inherit (import ../lib.nix)
    assert'
    containsRegex
    all
    any
    ;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  flakeText = builtins.readFile ../../src/flake.nix;

  parsedServices = builtins.fromJSON servicesJsonText;
  serviceNames = builtins.filter (n: parsedServices.${n} ? hosts) (builtins.attrNames parsedServices);

  knownHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  requiredServices = [
    "ollama"
    "litellm"
    "jellyfin"
    "discord-music-rpc"
    "sshd"
    "ssh-agent"
    "cloud-drive"
    "rdp"
    "linux-builder"
    "service-watchdog"
  ];

  userScopedServices = [
    "discord-music-rpc"
    "ssh-agent"
    "cloud-drive"
  ];

  macbookSystemServices = [
    "ollama"
    "litellm"
  ];
in
{
  tests = builtins.filter (x: x != null) [
    # --- Schema reference integrity ---
    (assert' (containsRegex ''services\.schema\.json'' servicesJsonText) "services.json must reference services.schema.json")

    # --- displayName field present in every service ---
    (assert' (all (
      name: parsedServices.${name} ? displayName
    ) serviceNames) "Every service must have a displayName field")

    # --- Required services present ---
    (assert' (all (
      name: builtins.hasAttr name parsedServices
    ) requiredServices) "All required services must be present in services.json")

    # --- Each service has at least one non-omitted host ---
    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
        hosts = builtins.attrNames entry.hosts;
      in
      any (h: entry.hosts.${h}.type != "omitted") hosts
    ) serviceNames) "Every service must have at least one non-omitted host")

    # --- All host keys are valid ---
    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
      in
      all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
    ) serviceNames) "All host keys must be MacBook, NixOS, or Windows")

    # --- Scope assertions: system-scoped services on MacBook ---
    (assert' (all (
      name: parsedServices.${name}.hosts.MacBook.scope == "system"
    ) macbookSystemServices) "ollama and litellm must be system-scoped on MacBook")

    # --- User-scoped entries must have justification ---
    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
        hosts = builtins.attrNames entry.hosts;
      in
      all (h: entry.hosts.${h} ? justification) hosts
    ) userScopedServices) "User-scoped services must have justification on every host")

    # --- service-watchdog structural ---
    (assert' (parsedServices ? service-watchdog) "service-watchdog present in services.json")
    (assert' (parsedServices.service-watchdog ? hosts) "service-watchdog has hosts")
    (assert' (parsedServices.service-watchdog ? displayName) "service-watchdog has displayName")

    # --- flake.nix wiring ---
    (assert' (containsRegex "service-watchdog" flakeText) "service-watchdog in flake.nix")
  ];

  success = true;
  message = "Service management structural tests passed";
}
