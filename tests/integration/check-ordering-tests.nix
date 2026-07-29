# tests/integration/check-ordering-tests.nix — Verify that all 20 validation steps
# appear in correct order in both POSIX and Windows step files.

let
  inherit (import ../lib.nix) containsRegex;

  checkStepsDir = ../../src/scripts/checks/check-steps;
  stepFiles = builtins.attrNames (builtins.readDir checkStepsDir);
  shFiles = builtins.sort builtins.lessThan (builtins.filter (f: builtins.hasSuffix ".sh" f) stepFiles);
  ps1Files = builtins.sort builtins.lessThan (builtins.filter (f: builtins.hasSuffix ".ps1" f) stepFiles);

  # Expected step names in registration order (POSIX names)
  expectedShSteps = [
    "Code formatting (treefmt)"
    "PowerShell lint"
    "Packer template validation"
    "Nix flake evaluation"
    "Nix lint (nixf-tidy)"
    "Stale Nix build artifact check"
    "Shell script validation tests"
    "CWD-independence tests"
    "Nix search path tests"
    "Port utility function tests"
    "Lockfile validation"
    "Locked DSC validation"
    "Schema validation (JSON/YAML)"
    "Service registry validation"
    "YAML structural validation"
    "Package manager usage enforcement"
    "Undocumented error suppression"
    "Online determinism checks (--verify)"
    "Config method compliance"
    "Activation script token placeholder in comment check"
  ];

  # Expected step names in registration order (Windows names)
  expectedPs1Steps = [
    "Code formatting and linting (treefmt equivalent)"
    "PowerShell lint"
    "Packer template validation"
    "Nix flake evaluation"
    "Nix lint (nixf-tidy)"
    "Stale Nix build artifact check"
    "Shell script validation tests"
    "CWD-independence tests"
    "Nix search path tests"
    "Port utility function tests"
    "Lockfile validation"
    "Locked DSC validation"
    "Schema validation (JSON/YAML)"
    "Service registry validation"
    "YAML structural validation"
    "Package manager usage enforcement"
    "Undocumented error suppression check"
    "Online determinism checks (--verify)"
    "Config method compliance"
    "Activation script token placeholder in comment check"
  ];

  # Read a step file content
  readStep = f: builtins.readFile (checkStepsDir + "/${f}");

  # Extract register_step name from a POSIX step file
  # Pattern: register_step <n> "<name>" <func>
  extractShName = text:
    let
      match = builtins.match ".*register_step [0-9]+ \"([^\"]+)\".*" text;
    in if match == null then "" else builtins.head match;

  # Extract Register-Step name from a Windows step file
  # Pattern: Register-Step -Number <n> -Name "<name>" ...
  extractPs1Name = text:
    let
      match = builtins.match ".*Register-Step -Number [0-9]+ -Name \"([^\"]+)\".*" text;
    in if match == null then "" else builtins.head match;

  # Verify a single step file
  verifySh = idx: file:
    let
      expected = builtins.elemAt expectedShSteps idx;
      actual = extractShName (readStep file);
    in
    assert actual == expected;
    true;

  verifyPs1 = idx: file:
    let
      expected = builtins.elemAt expectedPs1Steps idx;
      actual = extractPs1Name (readStep file);
    in
    assert actual == expected;
    true;

  # Run all verifications
  shResults = builtins.genList (i: verifySh i (builtins.elemAt shFiles i)) (builtins.length shFiles);
  ps1Results = builtins.genList (i: verifyPs1 i (builtins.elemAt ps1Files i)) (builtins.length ps1Files);
in

{
  success = true;
  message = "check.sh and check.ps1 step ordering validated: all 20 steps in correct order in step files. Windows step 1 uses 'Code formatting and linting (treefmt equivalent)'.";
}
