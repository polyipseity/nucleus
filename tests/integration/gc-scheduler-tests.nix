# tests/integration/gc-scheduler-tests.nix — System-scoped GC scheduler assertions.

let
  inherit (import ../lib.nix) containsRegex;

  posixBaseText = builtins.readFile ../../src/modules/posix-base.nix;
  macosNixText = builtins.readFile ../../src/modules/macos.nix;
  linuxNixText = builtins.readFile ../../src/modules/linux.nix;
  nixosActivationText = builtins.readFile ../../src/hosts/NixOS/activation.nix;
  nixStoreGcShText = builtins.readFile ../../src/scripts/services/nix-store-gc.sh;
  gcShText = builtins.readFile ../../scripts/gc.sh;
in

assert containsRegex "nucleus-nix-store-gc" posixBaseText;
assert containsRegex "launchd.daemons.gc-weekly" posixBaseText;
assert containsRegex "NUCLEUS_GC_GENERATIONS_KEEP" posixBaseText;
assert containsRegex "NUCLEUS_USERNAME = username" posixBaseText;
assert (builtins.match ".*launchd\\.agents\\.\"gc-weekly\".*" macosNixText == null);
assert (builtins.match ".*systemd\\.user\\.services\\.\"gc-weekly\".*" linuxNixText == null);
assert containsRegex "systemd.services.\"nucleus-nix-store-gc\"" nixosActivationText;
assert containsRegex "systemd.timers.\"nucleus-nix-store-gc\"" nixosActivationText;
assert containsRegex "systemd.services.\"nucleus-gc-weekly\"" nixosActivationText;
assert containsRegex "systemd.timers.\"nucleus-gc-weekly\"" nixosActivationText;
assert containsRegex "NUCLEUS_USERNAME=" nixosActivationText;
assert containsRegex "expire_profile_generations_intersection" nixStoreGcShText;
assert containsRegex "NUCLEUS_GC_USER_ONLY" gcShText;
assert containsRegex "_gc_dispatch_user_gc" gcShText;
assert containsRegex "duperemove-gc" gcShText;
assert containsRegex "gc_duperemove_store_if_available" gcShText;
assert (builtins.pathExists ../../src/scripts/services/duperemove-store.sh);

{
  success = true;
  message = "GC scheduler content assertions passed";
}
