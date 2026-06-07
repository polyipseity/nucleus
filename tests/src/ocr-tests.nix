# tests/src/ocr-tests.nix — Verify PaddleOCR provisioning across all hosts.
#
# Run with: nix-instantiate --eval tests/src/ocr-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  agentsText = builtins.readFile ../../src/modules/agents.nix;
  uvSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-UvSetup.ps1;
in
# POSIX (agents.nix): paddleocr in installUvTools desired list
assert containsRegex "paddleocr" agentsText;
# Windows (Invoke-UvSetup.ps1): paddleocr in desiredPackages array
assert containsRegex "paddleocr" uvSetupText;
true
