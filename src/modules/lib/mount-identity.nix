# src/modules/lib/mount-identity.nix — canonical supervisor unit identity for cloud mounts.
#
# The unit DEFINITION and the runner's health key must come from one definition.
# The runner records health against the id the watchdog enumerates back out of
# the supervisor, so a divergence silently orphans those records and disables
# loop detection: the mount restarts forever with nothing blocking it.
#
# macOS: the launchd Label IS the identity, and home-manager names the plist
# after it. NixOS: systemd appends .service, and that suffixed name is what the
# service commands and the watchdog enumerate.
#
# Pure data and functions only, no nixpkgs dependency, so the identity contract
# is testable on its own.
rec {
  # Base name of the unit that runs a mount.
  # Args: isDarwin (macOS?), mountId (registry mount id).
  unitName =
    isDarwin: mountId: if isDarwin then "local.cloud-mount.${mountId}" else "cloud-mount-${mountId}";

  # What the supervisor reports, the watchdog enumerates, and the runner keys
  # health on. systemd appends the unit suffix to that name, launchd does not.
  serviceId = isDarwin: mountId: "${unitName isDarwin mountId}${if isDarwin then "" else ".service"}";
}
