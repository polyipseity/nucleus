# tests/modules/windows-lockfile-path-tests.nix — Guard Windows lockfile path resolution.
#
# Windows modules resolve the consolidated lockfile as
# '<repo root>\src\lockfiles\lockfile.json'.  Several modules instead built
# '<repo root>\lockfiles\lockfile.json', which does not exist, so their version
# pins were silently never applied (Test-Path failed and the pin path was
# skipped).  This test keeps that defect class out of the tree.
#
# Run with: nix-instantiate --eval --strict tests/modules/windows-lockfile-path-tests.nix

let
  inherit (import ../lib.nix) assert';

  srcDir = ../.. + "/src";

  # Every .ps1 file under src/, found without import-from-derivation.
  walk =
    dir:
    builtins.concatMap (
      name:
      let
        type = (builtins.readDir dir).${name};
        path = dir + "/${name}";
      in
      if type == "directory" then
        walk path
      else if type == "regular" && builtins.match ".*[.]ps1" name != null then
        [ path ]
      else
        [ ]
    ) (builtins.attrNames (builtins.readDir dir));

  ps1Files = walk srcDir;

  lines = path: builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile path));

  # A lockfile path built with Join-Path is only valid when it names the src/
  # segment or walks up with '..' first; anything else points at a path that
  # does not exist.  Comments never call Join-Path, so help text is not matched.
  isOffender =
    path:
    builtins.any (
      line:
      builtins.match ".*Join-Path.*lockfiles[\\\\/]lockfile[.]json.*" line != null
      && builtins.match ".*(src[\\\\/]lockfiles|[.][.][\\\\/]).*" line == null
    ) (lines path);

  offenders = builtins.filter isOffender ps1Files;

  docsScanned = builtins.length ps1Files;

  allTestsPass = offenders == [ ] && docsScanned > 20;
in
{
  test_lockfile_paths_include_src = assert' (offenders == [ ])
    "every Join-Path lockfile reference must include the src/ segment (offenders: ${builtins.concatStringsSep ", " (map toString offenders)})";
  test_modules_scanned = assert' (docsScanned > 20)
    "the scan must reach the Windows module tree (found ${toString docsScanned} .ps1 files)";

  all_tests_pass = assert' allTestsPass "all Windows lockfile path invariants must hold";
  success = allTestsPass;
}
