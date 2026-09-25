# tests/modules/mount-identity-tests.nix — cloud-mount supervisor unit identity.
#
# The runner records health against an instance id; the watchdog enumerates that
# same id back out of the supervisor.  Both must resolve to ONE name per host, or
# the runner's records are orphaned and the mount gets no loop detection.  That
# regression shipped once (the NixOS runner used the macOS LaunchAgent label), so
# these tests bind the identity to BOTH consumers: the registry's declared unit
# paths and the id every existing service test uses.

let
  inherit (import ../lib.nix) assert';

  identity = import ../../src/modules/lib/mount-identity.nix;

  services = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  macEntry = services.cloud-drive.hosts.MacBook;
  linuxEntry = services.cloud-drive.hosts.NixOS;

  mountId = "iCloud";

  # What the runner is given, per host.
  macIdentity = identity.serviceId true mountId;
  linuxIdentity = identity.serviceId false mountId;

  # What the watchdog enumerates: `launchctl list` prints the Label, and
  # `systemctl list-units` prints the unit's installed name.  The registry's
  # unitPath states the installed name each host expects.
  unitPathBasename = entry: builtins.baseNameOf entry.unitPath;
  expand = template: builtins.replaceStrings [ "__INSTANCE__" ] [ mountId ] template;
  linuxFromRegistry = expand (unitPathBasename linuxEntry);
  macFromRegistry = builtins.replaceStrings [ ".plist" ] [ "" ] (expand (unitPathBasename macEntry));

  test_linux_identity_is_the_systemd_unit_name = assert' (
    linuxIdentity == "cloud-mount-iCloud.service"
  ) "NixOS identity must be the systemd unit name systemctl reports (cloud-mount-iCloud.service)";

  test_macos_identity_is_the_launchd_label = assert' (
    macIdentity == "local.cloud-mount.iCloud"
  ) "macOS identity must be the launchd Label home-manager installs the plist for";

  test_identity_matches_the_registry_unit_path = assert' (
    linuxIdentity == linuxFromRegistry && macIdentity == macFromRegistry
  ) "each host's identity must equal the installed unit name its services.json unitPath declares";

  test_identity_matches_the_registry_service_prefix = assert' (
    (
      builtins.substring 0 (builtins.stringLength linuxEntry.service) linuxIdentity == linuxEntry.service
    )
    && (builtins.substring 0 (builtins.stringLength macEntry.service) macIdentity == macEntry.service)
  ) "each host's identity must begin with the service prefix its services.json host entry declares";

  # THE REGRESSION: the NixOS runner used the macOS LaunchAgent label, so it wrote
  # health records the watchdog never read.  The two host identities must differ.
  test_linux_identity_is_not_the_macos_label =
    assert' (linuxIdentity != macIdentity && linuxIdentity != "local.cloud-mount.iCloud")
      "the NixOS identity must never be the macOS LaunchAgent label — that orphans the runner's health records";

  # systemd reports the unit-type suffix; launchd reports the bare Label.
  test_unit_type_suffix_is_host_specific = assert' (
    (builtins.match ".*\\.service" linuxIdentity != null)
    && (builtins.match ".*\\.service" macIdentity == null)
  ) "only the systemd identity carries the unit-type suffix";

  allTests = [
    test_linux_identity_is_the_systemd_unit_name
    test_macos_identity_is_the_launchd_label
    test_identity_matches_the_registry_unit_path
    test_identity_matches_the_registry_service_prefix
    test_linux_identity_is_not_the_macos_label
    test_unit_type_suffix_is_host_specific
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} mount-identity tests passed";
}
