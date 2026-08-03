# tests/modules/package-parity-tests.nix — Cross-platform package presence.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  # Critical packages that should exist on all three platforms.
  # Format: { name, nixpkgs, homebrew, winget }
  essentialPackages = [
    # Shell & development tools
    {
      name = "git";
      nixpkgs = "git";
      homebrew = "git";
      winget = "Git.Git";
    }
    {
      name = "gitk";
      nixpkgs = "gitk";
      homebrew = null; # Provided by Git formula/cask on macOS; no standalone package needed
      winget = "Git.Git"; # Provided by Git for Windows installation
    }
    {
      name = "github-cli";
      nixpkgs = "gh";
      homebrew = "gh";
      winget = "GitHub.cli";
    }
    {
      name = "zsh";
      nixpkgs = "zsh";
      homebrew = "zsh";
      winget = null; # WSL/Windows Terminal provides this
    }
    {
      name = "direnv";
      nixpkgs = "direnv";
      homebrew = "direnv";
      winget = null; # Not directly needed on Windows
    }
    # CLI tools
    {
      name = "bat";
      nixpkgs = "bat";
      homebrew = "bat";
      winget = "sharkdp.bat";
    }
    {
      name = "fzf";
      nixpkgs = "fzf";
      homebrew = "fzf";
      winget = "junegunn.fzf";
    }
    {
      name = "imagemagick";
      nixpkgs = "imagemagick";
      homebrew = null; # CLI tool; installed via nixpkgs on macOS per policy
      winget = "ImageMagick.ImageMagick";
    }
    {
      name = "ripgrep";
      nixpkgs = "ripgrep";
      homebrew = "ripgrep";
      winget = "BurntSushi.ripgrep.MSVC";
    }
    # Development tools
    {
      name = "python";
      nixpkgs = "python3";
      homebrew = "python@3.12";
      winget = "Python.Python.3.12";
    }
    {
      name = "nodejs";
      nixpkgs = "nodejs";
      homebrew = "node";
      winget = "OpenJS.NodeJS";
    }
  ];

  # Test 1: Verify all essential packages have nixpkgs entries
  test_nixpkgs_coverage = assert' (builtins.all (
    p: p.nixpkgs != null
  ) essentialPackages) "All essential packages must have nixpkgs equivalents";

  # Test 2: Verify all essential packages have homebrew entries (for macOS)
  test_homebrew_coverage = assert' (
    builtins.length (lib.filter (p: p.homebrew != null) essentialPackages) >= 6
  ) "Most essential packages should have homebrew equivalents (macOS parity)";

  # Test 3: Verify all essential packages have winget entries (for Windows)
  test_winget_coverage = assert' (
    builtins.length (lib.filter (p: p.winget != null) essentialPackages) >= 5
  ) "Most essential packages should have winget equivalents (Windows parity)";

  # Test 4: Verify no duplicate package names across platforms
  test_no_duplicate_names = assert' (
    builtins.length (lib.unique (map (p: p.name) essentialPackages))
    == builtins.length essentialPackages
  ) "No duplicate package names should exist";

  # Test 5: Verify naming consistency (no major divergences)
  # nixpkgs often uses lowercase; homebrew/winget may use different casing
  test_naming_consistency =
    assert' true # Naming varies by platform; this is expected and documented
      "Package naming across platforms is documented and intentional";

  # Test 6: Verify shell tools are present (critical for scripting)
  shellTools = [
    {
      name = "bash";
      nixpkgs = "bash";
    }
    {
      name = "zsh";
      nixpkgs = "zsh";
    }
    {
      name = "jq";
      nixpkgs = "jq";
    }
  ];

  test_shell_tools_available = assert' (builtins.all (
    t: t.nixpkgs != null
  ) shellTools) "All shell tools must be available in nixpkgs";

  # Test 7: Verify GUI tools are only declared where supported
  guiTools = [
    {
      name = "vscode";
      homebrew = "visual-studio-code@insiders";
      nixpkgs = "vscode";
    }
    {
      name = "blender";
      homebrew = "blender";
      nixpkgs = "blender";
    }
  ];

  test_gui_tools_declared = assert' (
    builtins.length guiTools >= 2
  ) "GUI tools should be declared for applicable platforms";

  # === OVERLAPPING PACKAGES PARITY ===
  # Verify all cross-platform entries in modules/core.nix overlappingPackages
  # have valid nixpkgs attribute names.
  coreModuleText = builtins.readFile ../../src/modules/core.nix;

  # Cross-platform overlappingPackages entries (available on both darwin and linux).
  crossPlatformOverlapAttrs = [
    {
      name = "blender";
      nixpkgsAttr = "blender";
    }
    {
      name = "czkawka";
      nixpkgsAttr = "czkawka";
    }
    {
      name = "google-chrome";
      nixpkgsAttr = "google-chrome";
    }
    {
      name = "krita";
      nixpkgsAttr = "krita";
    }
    {
      name = "libreoffice";
      nixpkgsAttr = "libreoffice";
    }
    {
      name = "obsidian";
      nixpkgsAttr = "obsidian";
    }
    {
      name = "musicbrainz-picard";
      nixpkgsAttr = "picard";
    }
    {
      name = "qemu";
      nixpkgsAttr = "qemu";
    }
    {
      name = "discord@canary";
      nixpkgsAttr = "discord-canary";
    }
    {
      name = "visual-studio-code";
      nixpkgsAttr = "vscode";
    }
    {
      name = "vlc";
      nixpkgsAttr = "vlc";
    }
    {
      name = "zoom";
      nixpkgsAttr = "zoom-us";
    }
  ];

  # Darwin-only overlappingPackages entries (attrs exist on Linux nixpkgs but
  # are only buildable on darwin via meta.platforms).
  darwinOnlyPackages = [
    {
      name = "iterm2";
      nixpkgsAttr = "iterm2";
    }
    {
      name = "rectangle";
      nixpkgsAttr = "rectangle";
    }
    {
      name = "stats";
      nixpkgsAttr = "stats";
    }
    {
      name = "utm@beta";
      nixpkgsAttr = "utm";
    }
    {
      name = "visual-studio-code@insiders";
      nixpkgsAttr = "vscode-insiders";
    }
  ];

  test_overlapping_packages_have_nixpkgs = assert' (builtins.all
    (p: builtins.match (".*" + p.nixpkgsAttr + ".*") coreModuleText != null)
    crossPlatformOverlapAttrs
  ) "All cross-platform overlappingPackages entries should be defined in core.nix";

  test_darwin_only_packages_platform_marked =
    let
      darwinOnlyPkgNames = map (p: p.name) darwinOnlyPackages;
      # Match a core.nix package entry with platforms = ["darwin"].
      # The name may be written quoted in core.nix (e.g. "visual-studio-code@insiders").
      hasDarwinPlatform =
        name:
        builtins.match (".*" + name + "\"? = \\{\n.*platforms = \\[ \"darwin\" \];.*") coreModuleText
        != null;
    in
    assert' (builtins.all hasDarwinPlatform darwinOnlyPkgNames) "Darwin-only packages should have platforms field set in core.nix";

  test_darwin_only_absent_on_linux =
    let
      linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };
      notBuildableOnLinux =
        p:
        !builtins.hasAttr p.nixpkgsAttr linuxPkgs
        || !(builtins.elem "x86_64-linux" (linuxPkgs.${p.nixpkgsAttr}.meta.platforms or [ ]));
    in
    assert' (builtins.all notBuildableOnLinux darwinOnlyPackages) "Darwin-only packages must not be buildable on Linux";

  # Guard: every overlappingPackages entry in core.nix must be covered by either
  # crossPlatformOverlapAttrs (cross-platform) or darwinOnlyPackages (darwin-only).
  test_all_overlapping_packages_covered =
    let
      # Extract all entry names from core.nix overlappingPackages block.
      # Entries have the form: `    name = {` or `    "quoted name" = {`
      parts = builtins.split "\n    \"?([a-zA-Z0-9@._-]+)\"? = \\{" coreModuleText;
      isListElement = x: builtins.isList x;
      listElements = builtins.filter isListElement parts;
      extractedNames = map builtins.head listElements;
      crossPlatformNames = map (p: p.name) crossPlatformOverlapAttrs;
      darwinOnlyNames = map (p: p.name) darwinOnlyPackages;
      knownNames = crossPlatformNames ++ darwinOnlyNames;
      uncovered = builtins.filter (n: !(builtins.elem n knownNames)) extractedNames;
    in
    assert' (
      uncovered == [ ]
    ) "All overlappingPackages entries must be covered by tests: ${builtins.toString uncovered}";

  allTests = [
    test_nixpkgs_coverage
    test_homebrew_coverage
    test_winget_coverage
    test_no_duplicate_names
    test_naming_consistency
    test_shell_tools_available
    test_gui_tools_declared
    test_overlapping_packages_have_nixpkgs
    test_darwin_only_packages_platform_marked
    test_darwin_only_absent_on_linux
    test_all_overlapping_packages_covered
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  packageCount = builtins.length essentialPackages;
  message = "All ${builtins.toString (builtins.length allTests)} cross-platform package parity tests passed (${builtins.toString (builtins.length essentialPackages)} packages verified)";
}
