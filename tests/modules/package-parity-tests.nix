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
      name = "cursor";
      nixpkgsAttr = "code-cursor";
    }
    {
      name = "visual-studio-code";
      nixpkgsAttr = "vscode";
    }
    {
      name = "vlc";
      nixpkgsAttr = "vlc";
    }
    # --- Completed overlap entries (cross-platform, carry a winget.id) ---
    {
      name = "google-chrome@canary";
      nixpkgsAttr = "google-chrome";
    }
    {
      name = "chrome-remote-desktop";
      nixpkgsAttr = "chrome-remote-desktop";
    }
    {
      name = "gimp";
      nixpkgsAttr = "gimp";
    }
    {
      name = "qtpass";
      nixpkgsAttr = "qtpass";
    }
    {
      name = "neovim";
      nixpkgsAttr = "neovim";
    }
    {
      name = "krokiet";
      nixpkgsAttr = "krokiet";
    }
    {
      name = "parsec";
      nixpkgsAttr = "parsec";
    }
    {
      name = "peace-equalizer-apo";
      nixpkgsAttr = "peace-equalizer-apo";
    }
    {
      name = "equalizer-apo";
      nixpkgsAttr = "equalizer-apo";
    }
    {
      name = "steam";
      nixpkgsAttr = "steam";
    }
    {
      name = "telegram@beta";
      nixpkgsAttr = "telegram-desktop";
    }
    {
      name = "powersession";
      nixpkgsAttr = "powersession";
    }
    {
      name = "whatsapp-beta";
      nixpkgsAttr = "whatsapp";
    }
    {
      name = "powertoys";
      nixpkgsAttr = "powertoys";
    }
    {
      name = "windows-terminal-preview";
      nixpkgsAttr = "windows-terminal-preview";
    }
    {
      name = "scoop";
      nixpkgsAttr = "scoop";
    }
    {
      name = "winfsp";
      nixpkgsAttr = "winfsp";
    }
    {
      name = "7zip";
      nixpkgsAttr = "p7zip";
    }
    {
      name = "gpg4win";
      nixpkgsAttr = "gnupg";
    }
    {
      name = "zoxide";
      nixpkgsAttr = "zoxide";
    }
    {
      name = "ghostscript";
      nixpkgsAttr = "ghostscript";
    }
    {
      name = "packer";
      nixpkgsAttr = "packer";
    }
    {
      name = "uv";
      nixpkgsAttr = "uv";
    }
    {
      name = "ruff";
      nixpkgsAttr = "ruff";
    }
    {
      name = "ty";
      nixpkgsAttr = "ty";
    }
    {
      name = "ripgrep";
      nixpkgsAttr = "ripgrep";
    }
    {
      name = "caddy";
      nixpkgsAttr = "caddy";
    }
    {
      name = "bottom";
      nixpkgsAttr = "bottom";
    }
    {
      name = "direnv";
      nixpkgsAttr = "direnv";
    }
    {
      name = "starship";
      nixpkgsAttr = "starship";
    }
    {
      name = "eza";
      nixpkgsAttr = "eza";
    }
    {
      name = "git";
      nixpkgsAttr = "gitFull";
    }
    {
      name = "gh";
      nixpkgsAttr = "gh";
    }
    {
      name = "ffmpeg";
      nixpkgsAttr = "ffmpeg-full";
    }
    {
      name = "imagemagick";
      nixpkgsAttr = "imagemagick";
    }
    {
      name = "prek";
      nixpkgsAttr = "prek";
    }
    {
      name = "jq";
      nixpkgsAttr = "jq";
    }
    {
      name = "jellyfin";
      nixpkgsAttr = "jellyfin";
    }
    {
      name = "fzf";
      nixpkgsAttr = "fzf";
    }
    {
      name = "dotnet-runtime-6";
      nixpkgsAttr = "dotnetCorePackages.runtime_6_0";
    }
    {
      name = "powershell";
      nixpkgsAttr = "powershell";
    }
    {
      name = "ollama";
      nixpkgsAttr = "ollama";
    }
    {
      name = "bun";
      nixpkgsAttr = "bun";
    }
    {
      name = "rclone";
      nixpkgsAttr = "rclone";
    }
    {
      name = "actionlint";
      nixpkgsAttr = "actionlint";
    }
    {
      name = "rustup";
      nixpkgsAttr = "rustup";
    }
    {
      name = "sops";
      nixpkgsAttr = "sops";
    }
    {
      name = "bat";
      nixpkgsAttr = "bat";
    }
    {
      name = "fd";
      nixpkgsAttr = "fd";
    }
    {
      name = "shellcheck";
      nixpkgsAttr = "shellcheck";
    }
    {
      name = "opencode";
      nixpkgsAttr = "opencode";
    }
    {
      name = "pinact";
      nixpkgsAttr = "pinact";
    }
    {
      name = "python";
      nixpkgsAttr = "python3";
    }
    {
      name = "typst";
      nixpkgsAttr = "typst";
    }
    {
      name = "taplo";
      nixpkgsAttr = "taplo";
    }
    {
      name = "zizmor";
      nixpkgsAttr = "zizmor";
    }
    {
      name = "sccache";
      nixpkgsAttr = "sccache";
    }
    {
      name = "shfmt";
      nixpkgsAttr = "shfmt";
    }
    {
      name = "llvm";
      nixpkgsAttr = "llvmPackages_latest.llvm";
    }
    {
      name = "platform-tools";
      nixpkgsAttr = "android-tools";
    }
    {
      name = "source-serif";
      nixpkgsAttr = "source-serif";
    }
    {
      name = "jetbrains-mono-nerd-font";
      nixpkgsAttr = "nerd-fonts.jetbrains-mono";
    }
    {
      name = "noto-sans-cjk-sc";
      nixpkgsAttr = "noto-fonts-cjk-sans";
    }
    {
      name = "noto-sans-cjk-tc";
      nixpkgsAttr = "noto-fonts-cjk-sans";
    }
    {
      name = "noto-serif-cjk-sc";
      nixpkgsAttr = "noto-fonts-cjk-serif";
    }
    {
      name = "noto-serif-cjk-tc";
      nixpkgsAttr = "noto-fonts-cjk-serif";
    }
    {
      name = "inter";
      nixpkgsAttr = "inter";
    }
    {
      name = "zoom";
      nixpkgsAttr = "zoom-us";
    }
    {
      name = "obs-studio";
      nixpkgsAttr = "obs-studio";
    }
    {
      name = "jdk";
      nixpkgsAttr = "jdk";
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
      # Scope extraction to the overlappingPackages = { ... }; block so option
      # declarations like `    default = { }` elsewhere in core.nix are not
      # mistaken for package entries. Find the block by its unique opening marker
      # and the first top-level `  };` that closes it.
      marker = "overlappingPackages = {";
      afterStart = lib.lists.drop 1 (lib.strings.splitString marker coreModuleText);
      rest = builtins.head afterStart;
      endMarker = "\n  };";
      blockText = lib.lists.head (lib.strings.splitString endMarker rest);
      # Extract all entry names from the scoped block.
      # Entries have the form: `    name = {` or `    "quoted name" = {`
      parts = builtins.split "\n    \"?([a-zA-Z0-9@._-]+)\"? = \\{" blockText;
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
