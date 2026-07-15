# tests/integration/check-ordering-tests.nix — Verify that all 16 validation steps appear in correct order in both check.sh and check.ps1.

let
  inherit (import ../lib.nix) containsRegex flatten;

  checkShText = builtins.readFile ../../scripts/check.sh;
  checkPs1Text = builtins.readFile ../../scripts/check.ps1;
in

# check.sh — verify step ordering via quoted step names from section() calls
assert containsRegex
  "[\"]PowerShell syntax validation[\"].*[\"]Packer template validation[\"].*[\"]Dead Nix code[\"].*[\"]Nix flake evaluation[\"].*[\"]Nix formatting [(]nixfmt[)][\"].*[\"]Nix lint [(]nixf-tidy[)][\"].*[\"]Stale Nix build artifact check[\"].*[\"]Shell script validation tests[\"].*[\"]CWD-independence tests[\"].*[\"]Nix search path tests[\"].*[\"]Port utility function tests[\"].*[\"]Lockfile validation[\"].*[\"]Locked DSC validation[\"].*[\"]Service registry validation[\"].*[\"]Package manager usage enforcement[\"].*[\"]Undocumented error suppression[\"].*[\"]Online determinism checks [(]--verify[)][\"].*"
  checkShText;

# check.ps1 — verify step ordering via step names with === suffix from Write-Output calls
assert containsRegex
  "PowerShell syntax validation ===.*Packer template validation ===.*Dead Nix code ===.*Nix flake evaluation ===.*Nix formatting [(]nixfmt[)] ===.*Nix lint [(]nixf-tidy[)] ===.*Stale Nix build artifact check ===.*Shell script validation tests ===.*CWD-independence tests ===.*Nix search path tests ===.*Port utility function tests ===.*Lockfile validation ===.*Locked DSC validation ===.*Service registry validation ===.*Package manager usage enforcement ===.*Undocumented error suppression check ===.*Online determinism checks [(]--verify[)] ==="
  checkPs1Text;

{
  success = true;
  message = "check.sh and check.ps1 step ordering validated: all 17 steps in correct order in both files";
}
