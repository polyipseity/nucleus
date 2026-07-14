# tests/integration/check-tests.nix — Content assertions for check.sh
# lockfile overlap detection and exception handling.
#
# Run with: nix-instantiate --eval tests/integration/check-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  checkShText = builtins.readFile ../../scripts/check.sh;

  # Also read check.ps1 for cross-validation
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
in

# Overlap exception list
assert containsRegex "_lf_overlap_exceptions" checkShText;
assert containsRegex "astral-sh\\.ty" checkShText;

# Promoted from WARNING to ERROR
assert containsRegex "ERROR:" checkShText;
assert containsRegex "exit 1" checkShText;

# Graceful missing-lockfile handling (step 4 fix)
assert containsRegex "lockfile\\.json not found — skipping section validation" checkShText;
assert containsRegex "lockfile\\.json could not be loaded — skipping section validation"
  checkPs1Text;

{
  success = true;
  message = "Check.sh content assertions passed (overlap, ERROR promotion, missing-lockfile guard)";
}
