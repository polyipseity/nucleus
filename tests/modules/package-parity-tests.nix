# tests/modules/package-parity-tests.nix: Cross-platform package presence.
#
# Verifies managedPackages in core.nix:
#   • every entry's nixpkgs attr resolves in nixpkgs
#   • dotted nixpkgs attribute paths resolve via lib.hasAttrByPath
#   • darwin-only packages have platforms = ["darwin"]
#   • darwin-only packages are not buildable on Linux
#   • linux-only packages have platforms = ["linux"]
#   • packages nixpkgs cannot provide on darwin have platforms = ["linux"]
#   • src/hosts/NixOS/desktop.nix installs nothing managedPackages provides
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

  # --- Linux-only packages, derived from nixpkgs ---
  # An entry is Linux-only when its nixpkgs attribute declares support for Linux
  # and not for Darwin: then the registry says so, which keeps the entry out of
  # the darwin nixpkgs list and out of the Homebrew formula and cask lists, and
  # records the intent.
  # The declared platforms decide it, since `lib.meta.availableOn` folds in
  # `meta.platforms` and `meta.badPlatforms`, read from the Linux package set: a
  # darwin evaluation of an unfree or broken attribute answers a different
  # question than "is this app Linux-only".
  # WHY: attribute presence cannot stand in, because nixpkgs defines the
  # attribute on every system; `alsa-utils` resolves in an aarch64-darwin package
  # set and is still Linux-only.
  darwinSystem = lib.systems.elaborate "aarch64-darwin";
  linuxSystem = lib.systems.elaborate "x86_64-linux";
  linuxPkgs' = import <nixpkgs> { system = "x86_64-linux"; };
  # One entry's own `nixpkgs = "…"`, read from its block text: `nixpkgsAttrs`
  # above is a flat list of every attribute in the file and cannot be keyed by
  # entry. Split rather than regex, because a POSIX ERE over multi-line text is
  # implementation-defined about `.` crossing newlines.
  nixpkgsAttrOf =
    name:
    let
      block = entryBlocks.${name} or "";
      parts = lib.strings.splitString "nixpkgs = \"" block;
    in
    if builtins.length parts < 2 then
      null
    else
      builtins.head (lib.strings.splitString "\"" (builtins.elemAt parts 1));
  linuxPackageOf =
    name:
    let
      attr = nixpkgsAttrOf name;
    in
    if attr == null then null else lib.attrByPath (lib.strings.splitString "." attr) null linuxPkgs';
  # Presence stays the entry filter: an entry with no `nixpkgs` attribute is not
  # a nix package at all.
  nixpkgsEntryNames = builtins.filter (name: nixpkgsAttrOf name != null) extractedNames;
  linuxOnlyPackageNames = builtins.filter (
    name:
    let
      pkg = linuxPackageOf name;
    in
    pkg != null && lib.meta.availableOn linuxSystem pkg && !(lib.meta.availableOn darwinSystem pkg)
  ) nixpkgsEntryNames;

  # Entries nixpkgs cannot provide on darwin at all, read the same way as
  # `linuxOnlyPackageNames`: `lib.meta.availableOn` over the Linux package set, so
  # an unfree or broken attribute does not answer a different question.  A null
  # package (attribute absent from the Linux set) is not a platform answer.
  darwinUnavailablePackageNames = builtins.filter (
    name:
    let
      pkg = linuxPackageOf name;
    in
    pkg != null && !(lib.meta.availableOn darwinSystem pkg)
  ) nixpkgsEntryNames;

  # macOS keeps an app that nixpkgs packages only for Linux: Homebrew carries
  # it, or the flake overlay replaces the attribute with a darwin build.
  # `platforms = [ "linux" ]` removes an entry from every darwin list, the
  # Homebrew ones included, because `managedPackagePlatformCompatible` gates
  # them all, so the marker is owed only where nothing else carries darwin.
  flakeText = builtins.readFile ../../src/flake.nix;
  darwinCarriedElsewhere =
    name: homebrewBlockOf name != "" || lib.hasInfix "${name} = prev.stdenv.mkDerivation" flakeText;

  # --- NixOS host package list ---
  # A host may not install by hand what managedPackages already provides: both
  # paths reach environment.systemPackages, so the duplicate survives only until
  # one of the two changes.  Compared against each entry's `nixpkgs` attribute,
  # because that is the name a host file writes for a managed package (`p7zip`
  # for the "7zip" entry).  Only the `environment.systemPackages` block is read,
  # so option paths and service settings elsewhere in the file cannot match.
  nixosDesktopText = builtins.readFile ../../src/hosts/NixOS/desktop.nix;
  nixosDesktopPackageList = builtins.head (
    lib.strings.splitString "\n    ];" (
      builtins.head (
        builtins.tail (lib.strings.splitString "environment.systemPackages =" nixosDesktopText)
      )
    )
  );
  desktopPackageTokenOf =
    line:
    lib.removePrefix "pkgs." (lib.strings.trim (builtins.head (lib.strings.splitString "#" line)));
  # List entries are one bare token per line; the `(with pkgs; [` opener, the
  # `])` close and the `++ lib.optionals …` scaffolding carry punctuation and
  # drop out.
  nixosDesktopPackageNames = builtins.filter (t: builtins.match "[a-zA-Z0-9._-]+" t != null) (
    map desktopPackageTokenOf (lib.strings.splitString "\n" nixosDesktopPackageList)
  );

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

  # Linux-only packages must set platforms = [ "linux" ] in core.nix, unless
  # macOS gets them some other way (Homebrew, or a flake overlay darwin build).
  # It constrains only what the derivation finds, so an app that nixpkgs
  # packages for both systems is never required to carry the marker.
  test_linux_only_packages_platform_marked =
    let
      unmarked = builtins.filter (
        name:
        let
          entryBlock = entryBlocks.${name} or null;
        in
        !(darwinCarriedElsewhere name)
        && (entryBlock == null || !lib.hasInfix "platforms = [ \"linux\" ]" entryBlock)
      ) linuxOnlyPackageNames;
    in
    assert' (unmarked == [ ])
      "Linux-only packages must set platforms = [ \"linux\" ] in core.nix; unmarked: ${lib.strings.concatStringsSep ", " unmarked}";

  # Entries nixpkgs cannot provide on darwin must say so with
  # `platforms = [ "linux" ]`: core.nix carries every platform-compatible entry
  # in the darwin nixpkgs list without probing availability, so the marker is the
  # only thing that keeps such an entry out of it.  The exemption above applies
  # for the same reason it does there, since the marker also removes an entry
  # from the Homebrew lists.
  test_darwin_unavailable_packages_declared =
    let
      unmarked = builtins.filter (
        name:
        !(darwinCarriedElsewhere name)
        && !lib.hasInfix "platforms = [ \"linux\" ]" (entryBlocks.${name} or "")
      ) darwinUnavailablePackageNames;
    in
    assert' (unmarked == [ ])
      "packages nixpkgs cannot provide on darwin must set platforms = [ \"linux\" ] in core.nix; unmarked: ${lib.strings.concatStringsSep ", " unmarked}";

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

  # src/hosts/NixOS/desktop.nix must not reinstall a managedPackages entry.
  # An entry is matched by its `nixpkgs` attribute (through `nixpkgsAttrOf`
  # rather than the flat `nixpkgsAttrs`, which is empty because it filters the
  # between-match strings instead of the capture groups), and the message names
  # the host-file token, which is the line to drop.
  test_nixos_desktop_has_no_registry_duplicates =
    let
      providedByRegistry = token: builtins.any (name: nixpkgsAttrOf name == token) extractedNames;
      duplicates = lib.unique (builtins.filter providedByRegistry nixosDesktopPackageNames);
    in
    assert' (builtins.length nixosDesktopPackageNames > 0 && duplicates == [ ])
      "src/hosts/NixOS/desktop.nix must not install what managedPackages already provides; drop the line for: ${lib.strings.concatStringsSep ", " duplicates}";

  allTests = [
    test_entry_names_valid
    test_registry_names_sorted
    test_no_duplicate_names
    test_managed_nixpkgs_attrs_resolve
    test_dotted_nixpkgs_paths_resolve
    test_darwin_only_packages_platform_marked
    test_linux_only_packages_platform_marked
    test_darwin_unavailable_packages_declared
    test_darwin_only_absent_on_linux
    test_homebrew_kind_documented
    test_homebrew_kind_has_name
    test_no_undocumented_homebrew_kind
    test_nixos_desktop_has_no_registry_duplicates
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  packageCount = builtins.length extractedNames;
  linuxOnlyCount = builtins.length linuxOnlyPackageNames;
  message = "All ${builtins.toString (builtins.length allTests)} cross-platform package parity tests passed (${builtins.toString (builtins.length extractedNames)} packages verified)";
}
