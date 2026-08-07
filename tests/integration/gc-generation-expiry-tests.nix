# tests/integration/gc-generation-expiry-tests.nix — GC generation intersection helper assertions.

let
  inherit (import ../lib.nix) containsRegex;

  expireLibText = builtins.readFile ../../src/scripts/lib/expire-profile-generations.sh;
  gcShText = builtins.readFile ../../scripts/gc.sh;
in

assert containsRegex "expire_profile_generations_intersection" expireLibText;
assert containsRegex "resolve_system_profile" expireLibText;
assert containsRegex "resolve_hm_profile" expireLibText;
assert containsRegex "--delete-generations \"\\$_epg_age\"" expireLibText;
assert containsRegex "--delete-generations \"\\+" expireLibText;
assert containsRegex "expire-profile-generations.sh" gcShText;
assert containsRegex "expire_profile_generations_intersection" gcShText;
assert containsRegex "--generations-keep" gcShText;
assert containsRegex "--system-generations-keep" gcShText;
assert containsRegex "--hm-generations-keep" gcShText;
assert containsRegex "--system-gc" gcShText;
assert containsRegex "NUCLEUS_GC_GENERATIONS_KEEP" gcShText;
assert containsRegex "NUCLEUS_GC_SYSTEM_GENERATIONS_KEEP" gcShText;
assert containsRegex "NUCLEUS_GC_HM_GENERATIONS_KEEP" gcShText;
assert (builtins.match ".*home-manager expire-generations.*" gcShText == null);
assert (builtins.match ".*nix_expiry_to_hm.*" gcShText == null);

{
  success = true;
  message = "GC generation expiry content assertions passed";
}
