# tests/modules/package-parity-tests.nix: Cross-platform package presence.
#
# Verifies managedPackages in core.nix:
#   • every entry's nixpkgs attr resolves in nixpkgs
#   • dotted nixpkgs attribute paths resolve via lib.hasAttrByPath
#   • darwin-only packages have platforms = ["darwin"]
#   • darwin-only packages are not buildable on Linux
#   • homebrew.kind is the documented formula|cask and carries a name
#
# Run with: nix-instantiate --eval tests/modules/package-parity-tests.nix

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  coreModuleText = builtins.readFile ../../src/modules/core.nix;

  # --- Extract managedPackages entry names from core.nix text ---
  # Scope extraction to the managedPackages = { ... }; block.
  marker = "managedPackages = {";
  afterStart = lib.lists.drop 1 (lib.strings.splitString marker coreModuleText);
  rest = builtins.head afterStart;
  endMarker = "\n  };";
  blockText = lib.lists.head (lib.strings.splitString endMarker rest);

  # Extract all entry names: `    name = {` or `    "quoted name" = {`
  parts = builtins.split "\n    \"?([a-zA-Z0-9@._-]+)\"? = \\{" blockText;
  isListElement = x: builtins.isList x;
  listElements = builtins.filter isListElement parts;
  extractedNames = map builtins.head listElements;

  # Entries are matched by source order, so this asserts the file's declared
  # order. Nix compares strings with strcmp, which is byte order, so the rule
  # needs no locale and no collation data.
  namePairs = lib.lists.genList (i: [
    (builtins.elemAt extractedNames i)
    (builtins.elemAt extractedNames (i + 1))
  ]) (builtins.length extractedNames - 1);
  outOfOrder = builtins.filter (p: builtins.elemAt p 0 >= builtins.elemAt p 1) namePairs;

  # --- Entry blocks keyed by name (structural parse) ---
  # WHY: the assertion needs each entry's real text, and forcing managedPackages
  # through the module system would drag in every host's config args (pkgs,
  # treefmtPackage, …), so this file checks the registry source.  A regex over
  # the whole file is not portable: Nix's regex is POSIX ERE, which rejects `\]`
  # outright (`error: invalid regular expression`, not a false result), and
  # whether `.` crosses a newline is implementation-defined.  Splitting on the
  # entry boundary instead hands each assertion the real block that follows
  # `name = {` up to the next entry.
  entryBlocks = builtins.listToAttrs (
    builtins.filter (x: x != null) (
      lib.lists.imap0 (
        i: el:
        if isListElement el && (i + 1) < builtins.length parts then
          {
            name = builtins.head el;
            value = builtins.elemAt parts (i + 1);
          }
        else
          null
      ) parts
    )
  );

  # --- Homebrew kind contract ---
  # The registry comment documents `homebrew = { kind = "formula"|"cask"; name }`
  # and the brew/cask filters in core.nix key off that kind, so a third value
  # drops the package from both lists without an error.  Each assertion below
  # works inside one entry's `homebrew = { ... }` text rather than over the file.
  homebrewBlockOf =
    name:
    let
      split = lib.strings.splitString "homebrew = {" (entryBlocks.${name} or "");
    in
    if builtins.length split < 2 then
      ""
    else
      builtins.head (lib.strings.splitString "}" (builtins.head (builtins.tail split)));

  declaredHomebrewKind =
    name:
    let
      pieces = lib.strings.splitString "kind = \"" (homebrewBlockOf name);
    in
    if builtins.length pieces == 2 then
      builtins.head (lib.strings.splitString "\"" (builtins.head (builtins.tail pieces)))
    else
      null;

  homebrewDeclaresName =
    name:
    let
      pieces = lib.strings.splitString "name = \"" (homebrewBlockOf name);
    in
    builtins.length pieces == 2 && !lib.hasPrefix "\"" (builtins.head (builtins.tail pieces));

  homebrewEntryNames = builtins.filter (name: homebrewBlockOf name != "") (
    builtins.attrNames entryBlocks
  );

  homebrewKindCarriesName =
    name: declaredHomebrewKind name == "formula" || declaredHomebrewKind name == "cask";

  # --- Extract nixpkgs attrs from core.nix text ---
  matches = builtins.split "nixpkgs = \"([^\"]+)\";" coreModuleText;
  isStr = x: builtins.isString x;
  nixpkgsStrings = builtins.filter isStr matches;
  nixpkgsAttrs = builtins.filter (s: builtins.match "[a-zA-Z0-9_.-]+" s != null) nixpkgsStrings;

  # --- Dotted nixpkgs attribute paths (regression guard) ---
  dottedNixpkgsPaths = [
    "dotnetCorePackages.runtime_6_0"
    "nerd-fonts.jetbrains-mono"
    "llvmPackages_latest.llvm"
    "llvmPackages.clang"
    "llvmPackages.lld"
    "llvmPackages.lldb"
  ];

  # --- Darwin-only packages (known set for platform check) ---
  darwinOnlyPackageNames = [
    "iterm2"
    "rectangle"
    "stats"
    "utm@beta"
    "visual-studio-code@insiders"
    "duti"
    "desktoppr"
    "pinentry_mac"
    "equaliser"
  ];

  # --- Packages without nixpkgs attr (WinGet-only / macOS-cask-only) ---

  # --- Tests ---

  # Every extracted name must be non-empty.
  test_entry_names_valid = assert' (
    builtins.length extractedNames > 0
  ) "managedPackages must have at least one entry";

  # managedPackages must be sorted by entry name in byte order.
  test_registry_names_sorted =
    assert' (outOfOrder == [ ])
      "managedPackages entries must be sorted by name, byte order; out of order: ${
        lib.strings.concatStringsSep ", " (
          map (p: "${builtins.elemAt p 0} before ${builtins.elemAt p 1}") outOfOrder
        )
      }";

  # No duplicate entry names.
  test_no_duplicate_names = assert' (
    builtins.length extractedNames == builtins.length (lib.unique extractedNames)
  ) "No duplicate package names in managedPackages";

  # All nixpkgs attrs extracted from core.nix must resolve.
  test_managed_nixpkgs_attrs_resolve =
    let
      pkgs' = import <nixpkgs> { };
      pathOf = s: lib.strings.splitString "." s;
      resolves = s: lib.hasAttrByPath (pathOf s) pkgs';
    in
    assert' (builtins.all resolves nixpkgsAttrs) "All managedPackages nixpkgs attrs must resolve in nixpkgs";

  # Dotted nixpkgs attribute paths must resolve via path traversal.
  test_dotted_nixpkgs_paths_resolve =
    let
      pkgs' = import <nixpkgs> { };
      pathOf = s: lib.strings.splitString "." s;
      resolves = s: lib.hasAttrByPath (pathOf s) pkgs';
    in
    assert' (builtins.all resolves dottedNixpkgsPaths) "Dotted nixpkgs attribute paths must resolve via lib.hasAttrByPath";

  # Darwin-only packages must have platforms = ["darwin"] in core.nix.
  test_darwin_only_packages_platform_marked =
    let
      hasDarwinPlatform =
        name:
        let
          entryBlock = entryBlocks.${name} or null;
        in
        entryBlock != null && lib.hasInfix "platforms = [ \"darwin\" ]" entryBlock;
      unmarked = builtins.filter (name: !hasDarwinPlatform name) darwinOnlyPackageNames;
    in
    assert' (unmarked == [ ])
      "Darwin-only packages must set platforms = [ \"darwin\" ] in core.nix; unmarked: ${lib.strings.concatStringsSep ", " unmarked}";

  # Darwin-only packages must not be buildable on Linux.
  test_darwin_only_absent_on_linux =
    let
      linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };
      darwinNixpkgsAttrs = [
        "iterm2"
        "rectangle"
        "stats"
        "utm"
        "vscode-insiders"
        "duti"
        "desktoppr"
        "pinentry_mac"
        "equaliser"
      ];
      notBuildableOnLinux =
        attr:
        !builtins.hasAttr attr linuxPkgs
        || !(builtins.elem "x86_64-linux" (linuxPkgs.${attr}.meta.platforms or [ ]));
    in
    assert' (builtins.all notBuildableOnLinux darwinNixpkgsAttrs) "Darwin-only packages must not be buildable on Linux";

  # Every entry with homebrew metadata declares the documented kind.
  test_homebrew_kind_documented =
    let
      validKind = kind: kind == "formula" || kind == "cask";
      invalid = builtins.filter (name: !validKind (declaredHomebrewKind name)) homebrewEntryNames;
    in
    assert' (builtins.length homebrewEntryNames > 0 && invalid == [ ])
      "homebrew.kind must be \"formula\" or \"cask\" in core.nix; invalid: ${lib.strings.concatStringsSep ", " invalid}";

  # A declared kind ships the name Homebrew installs.
  test_homebrew_kind_has_name =
    let
      named = builtins.filter homebrewKindCarriesName homebrewEntryNames;
      missing = builtins.filter (name: !homebrewDeclaresName name) named;
    in
    assert' (builtins.length named > 0 && missing == [ ])
      "homebrew entries declaring kind = formula|cask must set homebrew.name in core.nix; missing: ${lib.strings.concatStringsSep ", " missing}";

  # No entry reintroduces a kind the registry comment does not document.
  test_no_undocumented_homebrew_kind = assert' (
    !(lib.hasInfix "kind = \"brew\"" coreModuleText)
  ) "core.nix must not declare homebrew kind \"brew\" (documented values: formula, cask)";

  allTests = [
    test_entry_names_valid
    test_registry_names_sorted
    test_no_duplicate_names
    test_managed_nixpkgs_attrs_resolve
    test_dotted_nixpkgs_paths_resolve
    test_darwin_only_packages_platform_marked
    test_darwin_only_absent_on_linux
    test_homebrew_kind_documented
    test_homebrew_kind_has_name
    test_no_undocumented_homebrew_kind
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  packageCount = builtins.length extractedNames;
  message = "All ${builtins.toString (builtins.length allTests)} cross-platform package parity tests passed (${builtins.toString (builtins.length extractedNames)} packages verified)";
}
