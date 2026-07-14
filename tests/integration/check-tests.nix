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

  libShText = builtins.readFile ../../src/scripts/lib.sh;
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

# Pre-flight tool availability block
assert containsRegex "Pre-flight tool availability checks" checkShText;
assert containsRegex "require_command pwsh" checkShText;
assert containsRegex "require_command nixfmt" checkShText;
assert containsRegex "require_command yq" checkShText;
assert containsRegex "require_command jq" checkShText;
assert containsRegex "require_command deadnix" checkShText;
assert containsRegex "require_command nix" checkShText;
assert containsRegex "require_command packer" checkShText;

# ensure_tool function in lib.sh
assert containsRegex "ensure_tool" libShText;
assert containsRegex "run nucleus-apply" libShText;

# Group headers in check.sh header comment
assert containsRegex "Toolchain checks [(][0-9]+-[0-9]+[)]:" checkShText;
assert containsRegex "Nix checks [(][0-9]+-[0-9]+[)]:" checkShText;
assert containsRegex "Test suites [(][0-9]+-[0-9]+[)]:" checkShText;
assert containsRegex "Data integrity [(][0-9]+-[0-9]+[)]:" checkShText;
assert containsRegex "Policy/verification [(][0-9]+-[0-9]+[)]:" checkShText;

# Group headers in check.ps1 header comment
assert containsRegex "Toolchain checks [(][0-9]+-[0-9]+[)]:" checkPs1Text;
assert containsRegex "Nix checks [(][0-9]+-[0-9]+, stubs on Windows[)]:" checkPs1Text;
assert containsRegex "Test suites [(][0-9]+-[0-9]+, stubs on Windows[)]:" checkPs1Text;
assert containsRegex "Data integrity [(][0-9]+-[0-9]+[)]:" checkPs1Text;
assert containsRegex "Policy/verification [(][0-9]+-[0-9]+[)]:" checkPs1Text;

{
  success = true;
  message = "Check.sh content assertions passed (overlap, ERROR promotion, missing-lockfile guard, pre-flight, ensure_tool, group headers)";
}
