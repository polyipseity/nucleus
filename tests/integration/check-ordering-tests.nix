# tests/integration/check-ordering-tests.nix — Verify that all 21 validation steps appear in correct order in both check.sh and check.ps1.

let
  inherit (import ../lib.nix) containsRegex;

  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
in

# check.sh — verify step ordering via quoted step names from section() calls
assert containsRegex
  "[\"]Shell script formatting/linting [(]treefmt[)][\"].*[\"]PowerShell syntax validation[\"].*[\"]Packer template validation[\"].*[\"]Code formatting [(]treefmt[)][\"].*[\"]Nix flake evaluation[\"].*[\"]Nix lint [(]nixf-tidy[)][\"].*[\"]Stale Nix build artifact check[\"].*[\"]Shell script validation tests[\"].*[\"]CWD-independence tests[\"].*[\"]Nix search path tests[\"].*[\"]Port utility function tests[\"].*[\"]Lockfile validation[\"].*[\"]Locked DSC validation[\"].*[\"]Schema validation [(]JSON/YAML[)][\"].*[\"]Service registry validation[\"].*[\"]YAML structural validation[\"].*[\"]Package manager usage enforcement[\"].*[\"]Undocumented error suppression[\"].*[\"]Online determinism checks [(]--verify[)][\"].*[\"]Config method compliance[\"].*[\"]Activation script token placeholder in comment check[\"]"
  checkShText;

# check.ps1 — verify step ordering via step names with === suffix from Write-Output calls
assert containsRegex
  "Shell script formatting/linting [(]treefmt[)] ===.*PowerShell syntax validation ===.*Packer template validation ===.*Code formatting [(]treefmt[)] ===.*Nix flake evaluation ===.*Nix lint [(]nixf-tidy[)] ===.*Stale Nix build artifact check ===.*Shell script validation tests ===.*CWD-independence tests ===.*Nix search path tests ===.*Port utility function tests ===.*Lockfile validation ===.*Locked DSC validation ===.*Schema validation [(]JSON/YAML[)] ===.*Service registry validation ===.*YAML structural validation ===.*Package manager usage enforcement ===.*Undocumented error suppression check ===.*Online determinism checks [(]--verify[)] ===.*Config method compliance ===.*Activation script token placeholder in comment check ==="
  checkPs1Text;

{
  success = true;
  message = "check.sh and check.ps1 step ordering validated: all 21 steps in correct order in both files";
}
