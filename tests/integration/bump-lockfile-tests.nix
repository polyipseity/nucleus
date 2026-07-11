# tests/integration/bump-lockfile-tests.nix — Content assertions for the
# bump-lockfile.ps1 skip-guard removal (commit f5418f6).
#
# Verifies that Test-CommandAvailable, Write-Skip, and Write-SkipAll functions
# were removed, while Test-SectionEnabled and the code/insiders alternative
# selection pattern remain.
#
# Run with: nix-instantiate --eval tests/integration/bump-lockfile-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  notContainsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) == null;

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
