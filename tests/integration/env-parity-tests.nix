# tests/integration/env-parity-tests.nix — Windows env var parity between the Nix
# catalog and the Windows DSC files.
#
# Asserted in the Nix lane because a Windows host has no Nix toolchain, so the
# catalog cannot be evaluated there: this needs no Windows host and materializes
# no artifact. The parity assertions that need no catalog data (shell profile,
# apply.ps1 wiring) live in
# tests/platforms/Windows/modules/EnvVarParity.Tests.ps1, which test step 6 runs
# on Windows.
let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  config = { };

  envVars = import ../../src/modules/lib/env-secrets.nix {
    inherit config pkgs lib;
    username = "test";
    hostName = "NixOS";
  };

  repoRoot = ../..;

  # Both DSC files contain nothing but Microsoft.Windows.Environment/Variable
  # resources, each with exactly one settings.name. The resource count is
  # compared against the extracted name count because a resource whose shape
  # changes would otherwise read as absent, and every subset assertion below
  # would then pass vacuously.
  dscResourceMarker = "resource: Microsoft.Windows.Environment/Variable";
  dscNamePattern = "[ \t]*name:[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*";

  readDscVarNames =
    relativePath:
    let
      text = builtins.readFile (repoRoot + "/${relativePath}");
      names = builtins.map builtins.head (
        builtins.filter (match: match != null) (
          builtins.map (line: builtins.match dscNamePattern line) (lib.splitString "\n" text)
        )
      );
    in
    {
      inherit names;
      shapeOk =
        builtins.length (lib.tail (lib.splitString dscResourceMarker text)) == builtins.length names;
    };

  # Catalog vars Windows must not declare: the macOS GUI PATH, the Darwin build
  # SDK vars, the Nix SSL bundle, the macOS gpg-agent SSH socket, and the
  # live-checkout root (apply.ps1 writes it to the registry directly).
  # PLAYWRIGHT_BROWSERS_PATH is set from a config-sync module instead of DSC.
  windowsInapplicableVarNames = [
    "DEVELOPER_DIR"
    "LIBRARY_PATH"
    "NIX_SSL_CERT_FILE"
    "NUCLEUS_REPO_ROOT"
    "PATH"
    "SDKROOT"
    "SSH_AUTH_SOCK"
  ];
  syncOnlyVarNames = [ "PLAYWRIGHT_BROWSERS_PATH" ];

  dscRequiredVarNames = builtins.filter (
    name: !builtins.elem name (windowsInapplicableVarNames ++ syncOnlyVarNames)
  ) envVars.getAllNixVarNames;

  # An explicit Windows = null excludes a var from Windows parity checks.
  isUserSpecific = name: envVars.catalog.${name}.userSpecific or false;

  requiredUserVarNames = builtins.filter isUserSpecific dscRequiredVarNames;
  requiredMachineVarNames = builtins.filter (name: !isUserSpecific name) dscRequiredVarNames;

  userDsc = readDscVarNames "src/hosts/Windows/user/env.dsc.yml";
  systemDsc = readDscVarNames "src/hosts/Windows/system/env.dsc.yml";

  missingFrom = required: actual: builtins.filter (name: !builtins.elem name actual) required;
  absentFromCatalog = actual: required: builtins.filter (name: !builtins.elem name required) actual;

  userMissing = missingFrom requiredUserVarNames userDsc.names;
  userExtra = absentFromCatalog userDsc.names requiredUserVarNames;
  machineMissing = missingFrom requiredMachineVarNames systemDsc.names;
  machineExtra = absentFromCatalog systemDsc.names requiredMachineVarNames;

  joinNames = names: builtins.concatStringsSep ", " names;
in
assert lib.assertMsg userDsc.shapeOk
  "src/hosts/Windows/user/env.dsc.yml: resource count does not match its settings.name count — the parity parser must be updated";
assert lib.assertMsg systemDsc.shapeOk
  "src/hosts/Windows/system/env.dsc.yml: resource count does not match its settings.name count — the parity parser must be updated";
assert lib.assertMsg
  (builtins.length requiredUserVarNames > 0 && builtins.length requiredMachineVarNames > 0)
  "the catalog resolved no Windows-applicable env vars — the exclusion list or the catalog import is broken";
assert lib.assertMsg (
  userMissing == [ ]
) "user/env.dsc.yml is missing user-scoped catalog vars: ${joinNames userMissing}";
assert lib.assertMsg (userExtra == [ ])
  "user/env.dsc.yml declares vars that are not user-specific in the catalog: ${joinNames userExtra}";
assert lib.assertMsg (
  machineMissing == [ ]
) "system/env.dsc.yml is missing machine-scoped catalog vars: ${joinNames machineMissing}";
assert lib.assertMsg (machineExtra == [ ])
  "system/env.dsc.yml declares vars that are not machine-scoped in the catalog: ${joinNames machineExtra}";
{
  success = true;
  message = "Windows env var parity: ${toString (builtins.length requiredUserVarNames)} user-scope and ${toString (builtins.length requiredMachineVarNames)} machine-scope catalog vars match the DSC files";
}
