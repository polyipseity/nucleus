# tests/integration/svc-tests.nix — Structural invariant tests for service management.
#
# Validates services.json data integrity: schema reference, required services,
# host validity, scope correctness, and per-user justification requirements.
# Implementation-coupled grep assertions against script source text have been
# removed — those are now covered by check step 08 (service-registry) and the
# script-level tests in tests/scripts/.

let
  inherit (import ../lib.nix) assert' containsRegex;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;

  # Parsed services.json for structural assertions
  parsedServices = builtins.fromJSON servicesJsonText;
  serviceNames = builtins.filter (n: parsedServices.${n} ? hosts) (builtins.attrNames parsedServices);

  # Tail-recursive list helpers
  all =
    pred: list:
    if list == [ ] then
      true
    else if pred (builtins.head list) then
      all pred (builtins.tail list)
    else
      false;
  any =
    pred: list:
    if list == [ ] then
      false
    else if pred (builtins.head list) then
      true
    else
      any pred (builtins.tail list);

  knownHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  # Required services that must be present in services.json
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

  # Services with user scope that must carry a justification string
  userScopedServices = [
    "discord-music-rpc"
    "ssh-agent"
    "cloud-drive"
  ];

  # Services expected to be system-scoped on MacBook
  macbookSystemServices = [
    "ollama"
    "litellm"
  ];
in
{
  tests = builtins.filter (x: x != null) [
    # --- Schema reference integrity ---
    (assert' (containsRegex ''services\.schema\.json'' servicesJsonText)
      "services.json must reference services.schema.json")

    # --- displayName field present in every service ---
    (assert' (
      all (name: parsedServices.${name} ? displayName) serviceNames
    ) "Every service must have a displayName field")

    # --- Required services present ---
    (assert' (
      all (name: builtins.hasAttr name parsedServices) requiredServices
    ) "All required services must be present in services.json")

    # --- Each service has at least one non-omitted host ---
    (assert' (
      all (
        name:
        let
          entry = parsedServices.${name};
          hosts = builtins.attrNames entry.hosts;
        in
        any (h: entry.hosts.${h}.type != "omitted") hosts
      ) serviceNames
    ) "Every service must have at least one non-omitted host")

    # --- All host keys are valid ---
    (assert' (
      all (
        name:
        let
          entry = parsedServices.${name};
        in
        all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
      ) serviceNames
    ) "All host keys must be MacBook, NixOS, or Windows")

    # --- Scope assertions: system-scoped services on MacBook ---
    (assert' (
      all (name: parsedServices.${name}.hosts.MacBook.scope == "system") macbookSystemServices
    ) "ollama and litellm must be system-scoped on MacBook")

    # --- User-scoped entries must have justification ---
    (assert' (
      all (
        name:
        let
          entry = parsedServices.${name};
          hosts = builtins.attrNames entry.hosts;
        in
        all (h: entry.hosts.${h} ? justification) hosts
      ) userScopedServices
    ) "User-scoped services must have justification on every host")
  ];
  success = true;
  message = "Service management structural tests passed";
}
