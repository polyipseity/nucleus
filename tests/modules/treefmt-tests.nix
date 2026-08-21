# tests/modules/treefmt-tests.nix — treefmt.nix formatter enablement and pinact offline policy.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert' containsRegex;

  treefmtText = builtins.readFile ../../src/treefmt.nix;
  coreModuleText = builtins.readFile ../../src/modules/core.nix;

  test_treefmt_enables_repo_formatters =
    assert'
      (
        lib.hasInfix "shfmt = {" treefmtText
        && lib.hasInfix "useEditorConfig = true" treefmtText
        && lib.hasInfix "taplo.enable = true" treefmtText
        && lib.hasInfix "packer.enable = true" treefmtText
        && lib.hasInfix "actionlint.enable = true" treefmtText
        && lib.hasInfix "pinact = {" treefmtText
        && lib.hasInfix "zizmor.enable = true" treefmtText
        && !lib.hasInfix "typos = {" treefmtText
      )
      "treefmt.nix must enable shfmt, taplo, packer, actionlint, pinact, and zizmor without typos config block";

  test_treefmt_disables_mdformat_and_typos = assert' (
    lib.hasInfix "mdformat.enable = false" treefmtText
    && lib.hasInfix "typos.enable = false" treefmtText
    && containsRegex "# WHY:.*markdownlint" treefmtText
    && containsRegex "# WHY:.*false-positive" treefmtText
  ) "treefmt.nix must keep mdformat and typos explicitly disabled with documented rationale";

  test_treefmt_pinact_offline_options = assert' (
    lib.hasInfix "update = false" treefmtText
    && lib.hasInfix "verify = false" treefmtText
    && lib.hasInfix "settings.formatter.pinact.options" treefmtText
    && lib.hasInfix "\"--fix=false\"" treefmtText
    && lib.hasInfix "\"--no-api\"" treefmtText
  ) "treefmt.nix must configure pinact for offline --fix=false --no-api checks";

  test_core_provisions_formatter_packages = assert' (
    lib.hasInfix "nixpkgs = \"shfmt\";" coreModuleText
    && lib.hasInfix "nixpkgs = \"taplo\";" coreModuleText
    && lib.hasInfix "nixpkgs = \"actionlint\";" coreModuleText
    && lib.hasInfix "nixpkgs = \"pinact\";" coreModuleText
    && lib.hasInfix "nixpkgs = \"zizmor\";" coreModuleText
    && !lib.hasInfix "nixpkgs = \"typos\";" coreModuleText
  ) "core.nix managedPackages must provision formatter CLIs without typos";

  allTests = [
    test_treefmt_enables_repo_formatters
    test_treefmt_disables_mdformat_and_typos
    test_treefmt_pinact_offline_options
    test_core_provisions_formatter_packages
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} treefmt tests passed";
  testNames = [
    "1: treefmt.nix enables repo-relevant formatters without typos"
    "2: treefmt.nix keeps mdformat and typos disabled with WHY"
    "3: treefmt.nix configures pinact offline options"
    "4: core.nix provisions formatter packages without typos"
  ];
}
