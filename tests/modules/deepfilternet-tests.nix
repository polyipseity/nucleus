# tests/modules/deepfilternet-tests.nix: DeepFilterNet3 ONNX model pin and deployment.
#
# Verifies:
#   • the lockfile `deepfilternet` section is non-empty and every entry is a
#     {url, revision, hash} object whose url embeds its own revision
#   • the schema declares deepfilternet as a property and a required root field
#   • POSIX deployment is wired: deepfilternet.nix exists, is imported by
#     home.nix, and the fetch script exists
#   • Windows deployment is wired: Sync-DeepFilterNetModel.ps1 exists and is
#     dot-sourced/called from apply.ps1
#   • enforcement probes are defined and wired in both POSIX and PowerShell libs
#
# Run with:
#   NIX_PATH="nixpkgs=/nix/store/pnb7zm1bb7a7i5005i7h5r1gh45p554i-source" \
#     nix-instantiate --eval --strict tests/modules/deepfilternet-tests.nix

let
  inherit (import ../lib.nix) assert';

  lib = import <nixpkgs/lib>;

  repoRoot = ../..;
  readRepo = path: builtins.readFile (repoRoot + "/${path}");
  hasPath = path: builtins.pathExists (repoRoot + "/${path}");

  lockfile = builtins.fromJSON (readRepo "src/lockfiles/lockfile.json");
  schema = builtins.fromJSON (readRepo "src/lockfiles/lockfile.schema.json");

  deepfilternetPins = lockfile.deepfilternet or { };
  deepfilternetModels = lib.attrNames deepfilternetPins;

  sectionNotEmpty = deepfilternetModels != [ ];

  pinIsWellFormed =
    name:
    let
      pin = deepfilternetPins.${name};
      url = pin.url or "";
      revision = pin.revision or "";
    in
    lib.isAttrs pin
    && lib.hasPrefix "sha256-" (pin.hash or "")
    && lib.hasPrefix "https://" url
    && lib.hasInfix revision url
    && (builtins.stringLength revision) == 40;

  schemaHasProperty = lib.hasAttrByPath [ "properties" "deepfilternet" ] schema;
  schemaRequires = schema.required or [ ];
  schemaRequiresSection = lib.elem "deepfilternet" schemaRequires;

  homeNixText = readRepo "src/modules/home.nix";
  homeImportsDeepfilternet = lib.hasInfix "./deepfilternet.nix" homeNixText;

  deepfilternetModuleExists = hasPath "src/modules/deepfilternet.nix";
  deepfilternetFetchScriptExists = hasPath "src/scripts/ai/fetch-deepfilternet-models.sh";

  syncPs1Exists = hasPath "src/platforms/Windows/modules/user/Sync-DeepFilterNetModel.ps1";
  applyPs1Text = readRepo "src/hosts/Windows/apply.ps1";
  applyDotSourcesSync =
    lib.hasInfix "Sync-DeepFilterNetModel.ps1" applyPs1Text
    && lib.hasInfix "Sync-DeepFilterNetModel" applyPs1Text;

  posixEnforcementText = readRepo "src/scripts/checks/lockfile-enforcement-lib.sh";
  psEnforcementText = readRepo "src/scripts/checks/lockfile-enforcement-lib.ps1";
  posixProbeDefined = lib.hasInfix "_lfe_check_deepfilternet()" posixEnforcementText;
  posixProbeWired = lib.hasInfix "_lfe_check_deepfilternet \"$_lf_data\"" posixEnforcementText;
  psProbeWired =
    lib.hasInfix "deepfilternet" psEnforcementText
    && lib.hasInfix "Get-NucleusUserRoot" psEnforcementText;

  allTests = [
    (assert' sectionNotEmpty "the lockfile must carry a non-empty deepfilternet section")
    (assert' schemaHasProperty "lockfile schema must declare a deepfilternet property")
    (assert' schemaRequiresSection "lockfile schema must require the deepfilternet section")
    (assert' deepfilternetModuleExists "src/modules/deepfilternet.nix must exist")
    (assert' homeImportsDeepfilternet "src/modules/home.nix must import ./deepfilternet.nix")
    (assert' deepfilternetFetchScriptExists "src/scripts/ai/fetch-deepfilternet-models.sh must exist")
    (assert' syncPs1Exists "src/platforms/Windows/modules/user/Sync-DeepFilterNetModel.ps1 must exist")
    (assert' applyDotSourcesSync "src/hosts/Windows/apply.ps1 must dot-source and call Sync-DeepFilterNetModel")
    (assert' posixProbeDefined "_lfe_check_deepfilternet must be defined in the POSIX enforcement lib")
    (assert' posixProbeWired "_lfe_check_deepfilternet must be wired into the POSIX enforcement entry point")
    (assert' psProbeWired "PowerShell enforcement must verify the deepfilternet model under the nucleus user root")
  ]
  ++ lib.map (
    name:
    assert' (pinIsWellFormed name) "deepfilternet.$name must be a {url, revision, hash} object whose url embeds its 40-character revision"
  ) deepfilternetModels;
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} DeepFilterNet model tests passed (${toString (builtins.length deepfilternetModels)} hashed model pin(s))";
}
