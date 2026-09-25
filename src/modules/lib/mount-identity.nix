# src/modules/lib/mount-identity.nix — canonical supervisor unit identity for cloud mounts.
#
# The unit DEFINITION and the runner's recorded health key must derive from one
# definition.  The runner records health against the id the watchdog enumerates
# back out of the supervisor, so a divergence between the two silently orphans
# the runner's records and disables loop detection for that mount — the mount
# keeps restarting with nothing ever blocking it.
#
# macOS: the launchd Label IS the unit identity, and home-manager names the
#   installed plist after it.
# NixOS: systemd names the unit <base>.service, and that suffixed name is the
#   identity every service command and the watchdog enumerate.
#
# Pure data and functions only — no nixpkgs dependency, so the identity
# contract is testable on its own.
rec {
  # Base name of the unit that runs a mount.
  # Args: isDarwin — whether the host platform is macOS; mountId — registry mount id.
  unitName =
    isDarwin: mountId: if isDarwin then "local.cloud-mount.${mountId}" else "cloud-mount-${mountId}";

  # Canonical runtime identity of the unit: what the supervisor reports, what the
  # watchdog enumerates, and the key the runner records health against.
  # systemd appends the unit-type suffix to the name it reports; launchd does not.
  serviceId = isDarwin: mountId: "${unitName isDarwin mountId}${if isDarwin then "" else ".service"}";
}
