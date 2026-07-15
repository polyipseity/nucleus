# tests/integration/ocr-tests.nix — Verify PaddleOCR provisioning across all hosts.

let
  inherit (import ../lib.nix) containsRegex flatten;

  agentsText = builtins.readFile ../../src/modules/agents.nix;
  uvSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-UvSetup.ps1;
in
# POSIX (agents.nix): paddleocr in installUvTools desired list
assert containsRegex "paddleocr" agentsText;
# Windows (Invoke-UvSetup.ps1): paddleocr in desiredPackages array
assert containsRegex "paddleocr" uvSetupText;
{
  success = true;
  message = "PaddleOCR provisioning cross-host tests passed";
}
