# tests/modules/host-platform-registry-tests.nix — host-platform registry invariants.

let
  hp = import ../../src/modules/lib/host-platform.nix { };

  inherit (import ../lib.nix) assert';

  test_host_keys = assert' (
    hp.hostKeys == [
      "MacBook"
      "NixOS"
      "Windows"
    ]
  ) "hostKeys must be MacBook, NixOS, Windows";

  test_platform_keys = assert' (
    hp.platformKeys == [
      "macOS"
      "NixOS"
      "Windows"
    ]
  ) "platformKeys must be macOS, NixOS, Windows";

  test_platform_for_host_macbook = assert' (
    hp.platformForHost "MacBook" == "macOS"
  ) "MacBook must map to macOS platform";

  test_platform_for_host_nixos = assert' (
    hp.platformForHost "NixOS" == "NixOS"
  ) "NixOS must map to NixOS platform";

  test_host_for_platform_macos = assert' (
    hp.hostForPlatform "macOS" == "MacBook"
  ) "macOS platform must map back to MacBook host";

  test_flags_on_platform_only = assert' (
    (hp.flagsForPlatform "macOS").darwin
    && (hp.flagsForPlatform "macOS").posix
    && !(hp.flagsForPlatform "macOS").linux
    && !(hp.flagsForPlatform "macOS").win32
  ) "macOS platform flags must be darwin+posix";

  test_flags_for_host_derived = assert' (
    hp.flagsForHost "MacBook" == hp.flagsForPlatform "macOS"
  ) "flagsForHost must derive from platform, not host JSON";

  test_hosts_have_no_flags_attr = assert' (builtins.all (
    h: !(hp.hosts.${h} ? flags)
  ) hp.hostKeys) "host entries must not contain flags — flags belong on platforms only";

  test_validate_host_platform_ref_ok = assert' (
    hp.validateHostPlatformRef "Windows" "Windows" == null
  ) "validateHostPlatformRef must accept matching host/platform pairs";

  test_validate_host_platform_ref_fail =
    (builtins.tryEval (hp.validateHostPlatformRef "MacBook" "NixOS")).success == false;

  services = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);

  serviceNames = builtins.filter (n: builtins.substring 0 1 n != "$") (builtins.attrNames services);

  test_services_host_platform_refs = assert' (
    builtins.all (
      svcName:
      let
        hosts = services.${svcName}.hosts or { };
      in
      builtins.all (
        host: hp.validateHostPlatformRef host hosts.${host}.platform == null
      ) (builtins.attrNames hosts)
    ) serviceNames
  ) "every services.json host platform ref must match host-platform-registry.json";

  test_services_hosts_have_no_flags = assert' (
    builtins.all (
      svcName:
      let
        hosts = services.${svcName}.hosts or { };
      in
      builtins.all (host: !(hosts.${host} ? flags)) (builtins.attrNames hosts)
    ) serviceNames
  ) "services.json host entries must not contain flags";

in
{
  ok =
    test_host_keys == null
    && test_platform_keys == null
    && test_platform_for_host_macbook == null
    && test_platform_for_host_nixos == null
    && test_host_for_platform_macos == null
    && test_flags_on_platform_only == null
    && test_flags_for_host_derived == null
    && test_hosts_have_no_flags_attr == null
    && test_validate_host_platform_ref_ok == null
    && test_validate_host_platform_ref_fail
    && test_services_host_platform_refs == null
    && test_services_hosts_have_no_flags == null;
}
