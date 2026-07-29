# tests/integration/check-ordering-tests.nix — Verify that all 20 check step files
# exist for both POSIX and Windows with consecutive 1-20 numbering and matching
# inline register_step / Register-Step calls.

let
  inherit (import ../lib.nix) containsRegex;

  checkStepsDir = ../../src/scripts/checks/check-steps;
  checkStepsFiles = builtins.attrNames (builtins.readDir checkStepsDir);
  hasSuffix = suffix: str: builtins.match ".*${suffix}" str != null;

  # Sorted lists of step files
  shFiles = builtins.sort builtins.lessThan (builtins.filter (f: hasSuffix ".sh" f) checkStepsFiles);
  ps1Files = builtins.sort builtins.lessThan (builtins.filter (f: hasSuffix ".ps1" f) checkStepsFiles);

  # Read a step file by name
  readStep = name: builtins.readFile (checkStepsDir + "/${name}");

  # Extract the integer step number from a filename prefix (e.g., "01" -> "1")
  fileStepNumStr = f: builtins.head (builtins.match "0*([0-9]+)-.*" f);

  # Extract step number from register_step call (POSIX)
  shStepNumStr = f: builtins.head (builtins.match ".*register_step ([0-9]+) .*" (readStep f));

  # Extract step number from Register-Step call (Windows)
  ps1StepNumStr = f: builtins.head (builtins.match ".*Register-Step -Number ([0-9]+) .*" (readStep f));

  # Verify file prefix matches inline step number
  checkSh = f: (shStepNumStr f) == (fileStepNumStr f);
  checkPs1 = f: (ps1StepNumStr f) == (fileStepNumStr f);

  # Expected step numbers as strings: "1", "2", ..., "20"
  expectedNums = builtins.genList (i: toString (i + 1)) 20;
in

# ---- POSIX step files ----

assert builtins.length shFiles == 20;
assert map shStepNumStr shFiles == expectedNums;
assert builtins.all checkSh shFiles;

# ---- Windows step files ----

assert builtins.length ps1Files == 20;
assert map ps1StepNumStr ps1Files == expectedNums;
assert builtins.all checkPs1 ps1Files;

{
  success = true;
  message = "All 20 POSIX and 20 Windows check step files validated: consecutive 1-20 numbering with matching inline register_step/Register-Step calls. Windows step 1 uses 'Code formatting and linting (treefmt equivalent)'.";
}
