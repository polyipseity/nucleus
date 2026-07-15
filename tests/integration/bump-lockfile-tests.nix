# tests/integration/bump-lockfile-tests.nix — Content assertions for the bump-lockfile.ps1 skip-guard removal.

let
  inherit (import ../lib.nix) containsRegex flatten;

  notContainsRegex = pattern: haystack: !containsRegex pattern haystack;

  bumpLockfilePs1Text = builtins.readFile ../../scripts/bump-lockfile.ps1;
in

# Removed skip-guard functions (commit f5418f6)
assert notContainsRegex "Test-CommandAvailable" bumpLockfilePs1Text;
assert notContainsRegex "Write-Skip" bumpLockfilePs1Text;
assert notContainsRegex "Write-SkipAll" bumpLockfilePs1Text;

# Test-SectionEnabled still present
assert containsRegex "Test-SectionEnabled" bumpLockfilePs1Text;

# code / code-insiders alternative selection pattern
assert containsRegex "code-insiders" bumpLockfilePs1Text;

{
  success = true;
  message = "Bump-lockfile content assertions passed";
}
