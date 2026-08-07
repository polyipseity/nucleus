# tests/modules/pwsh-naming-manifest-tests.nix — PowerShell naming manifest wiring.

let
  inherit (import ../lib.nix) assert' containsRegex;

  manifestText = builtins.readFile ../../scripts/pwsh-naming-manifest.json;
  checkerText = builtins.readFile ../../scripts/check-pwsh-naming.ps1;
  checkStepShText = builtins.readFile ../../src/scripts/checks/check-steps/02-powershell-lint.sh;
  checkStepPs1Text = builtins.readFile ../../src/scripts/checks/check-steps/02-powershell-lint.ps1;

  manifest = builtins.fromJSON manifestText;

  test_manifest_has_schema = assert' (containsRegex ''"\$schema": "./pwsh-naming-manifest.schema.json"'' manifestText) "pwsh-naming-manifest.json must inline its schema reference";

  test_checker_reads_manifest = assert' (
    containsRegex "pwsh-naming-manifest.json" checkerText
    && containsRegex "requiredNames" checkerText
    && containsRegex "forbiddenNames" checkerText
  ) "check-pwsh-naming.ps1 must validate required and forbidden names";

  test_check_steps_wired = assert' (
    containsRegex "check-pwsh-naming.ps1" checkStepShText
    && containsRegex "check-pwsh-naming.ps1" checkStepPs1Text
  ) "check step 02 must invoke check-pwsh-naming.ps1 on whole-repo runs";

  test_required_paths_exist =
    let
      paths = builtins.attrValues manifest.requiredNames;
      missing = builtins.filter (path: !(builtins.pathExists ../../${path})) paths;
    in
    assert' (missing == [ ]) "requiredNames paths must exist: ${builtins.toJSON missing}";

  allTests = [
    test_manifest_has_schema
    test_checker_reads_manifest
    test_check_steps_wired
    test_required_paths_exist
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} pwsh naming manifest tests passed";
}
