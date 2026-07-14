# tests/integration/check-ordering-tests.nix — Validates that all 16
# validation steps appear in the correct order in both check.sh and
# check.ps1.
#
# Uses implementation-specific patterns to distinguish section-header
# calls from header-comment mentions (each step name appears in both).
# For check.sh, patterns match quoted step names from section() calls
# using [\"] bracket expressions for literal double-quotes.
# For check.ps1, patterns match step names followed by ` ===` from
# Write-Output calls.
#
# Step 15 differs between files: check.sh has "Undocumented error
# suppression" (no "check"), check.ps1 has "Undocumented error
# suppression check".
#
# Bracket expressions [(] [)] [\"] for literal parens/quotes since POSIX
# ERE rejects \( and \".
#
# Run with: nix-instantiate --eval tests/integration/check-ordering-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
in

# check.sh — verify step ordering via quoted step names from section() calls
assert containsRegex
  "[\"]PowerShell syntax validation[\"].*[\"]Packer template validation[\"].*[\"]Dead Nix code[\"].*[\"]Nix flake evaluation[\"].*[\"]Nix formatting [(]nixfmt[)][\"].*[\"]Stale Nix build artifact check[\"].*[\"]Shell script validation tests[\"].*[\"]CWD-independence tests[\"].*[\"]Nix search path tests[\"].*[\"]Port utility function tests[\"].*[\"]Lockfile validation[\"].*[\"]Locked DSC validation[\"].*[\"]Service registry validation[\"].*[\"]Package manager usage enforcement[\"].*[\"]Undocumented error suppression[\"].*[\"]Online determinism checks [(]--verify[)][\"].*"
  checkShText;

# check.ps1 — verify step ordering via step names with === suffix from Write-Output calls
assert containsRegex
  "PowerShell syntax validation ===.*Packer template validation ===.*Dead Nix code ===.*Nix flake evaluation ===.*Nix formatting [(]nixfmt[)] ===.*Stale Nix build artifact check ===.*Shell script validation tests ===.*CWD-independence tests ===.*Nix search path tests ===.*Port utility function tests ===.*Lockfile validation ===.*Locked DSC validation ===.*Service registry validation ===.*Package manager usage enforcement ===.*Undocumented error suppression check ===.*Online determinism checks [(]--verify[)] ==="
  checkPs1Text;

{
  success = true;
  message = "check.sh and check.ps1 step ordering validated: all 16 steps in correct order in both files";
}
