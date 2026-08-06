# tests/integration/sccache-gc-tests.nix — Content assertions for sccache cache clearing.

let
  inherit (import ../lib.nix) containsRegex;

  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;
  gcShText = builtins.readFile ../../scripts/gc.sh;
  gcPs1Text = builtins.readFile ../../scripts/gc.ps1;
  sccacheGcShText = builtins.readFile ../../src/scripts/services/sccache-gc.sh;
  sccacheGcPs1Text = builtins.readFile ../../src/scripts/services/sccache-gc.ps1;
  sccacheMgmtPs1Text = builtins.readFile ../../src/hosts/Windows/modules/Invoke-SccacheManagement.ps1;
  schedulerText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
in

# --- lib.sh: sccache helpers ---
assert containsRegex "sccache_cache_dir\\(\\)" libShText;
assert containsRegex "clear_sccache_cache\\(\\)" libShText;
assert containsRegex "sccache --stop-server" libShText;
assert (builtins.match ".*sccache --clear.*" libShText == null);

# --- gc.sh: delegates to clear_sccache_cache ---
assert containsRegex "clear_sccache_cache" gcShText;
assert (builtins.match ".*sccache --clear.*" gcShText == null);

# --- sccache-gc service scripts ---
assert containsRegex "clear_sccache_cache" sccacheGcShText;
assert containsRegex "Clear-SccacheCache" sccacheGcPs1Text;
assert containsRegex "Invoke-SccacheManagement.ps1" sccacheGcPs1Text;

# --- Windows gc + scheduler ---
assert containsRegex "Clear-SccacheCache" gcPs1Text;
assert containsRegex "Invoke-SccacheManagement.ps1" gcPs1Text;
assert containsRegex "sccache-gc.ps1" schedulerText;
assert (builtins.match ".*sccache --clear.*" schedulerText == null);

# --- Invoke-SccacheManagement.ps1 ---
assert containsRegex "Get-SccacheCacheDir" sccacheMgmtPs1Text;
assert containsRegex "Mozilla\\\\sccache" sccacheMgmtPs1Text;

{
}
