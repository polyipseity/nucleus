# tests/integration/check-tests.nix — Content assertions for check.sh
# lockfile overlap detection and exception handling.
#
# Run with: nix-instantiate --eval tests/integration/check-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  checkShText = builtins.readFile ../../scripts/check.sh;
in

# Overlap exception list
assert containsRegex "_lf_overlap_exceptions" checkShText;
assert containsRegex "astral-sh\\.ty" checkShText;

# Promoted from WARNING to ERROR
assert containsRegex "ERROR:" checkShText;
assert containsRegex "exit 1" checkShText;

true
