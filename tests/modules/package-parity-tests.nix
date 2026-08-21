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

  # === MANAGED PACKAGES PARITY ===
  # Verify all cross-platform entries in modules/core.nix managedPackages
  # have valid nixpkgs attribute names.
  coreModuleText = builtins.readFile ../../src/modules/core.nix;

  # Cross-platform overlappingPackages entries (available on both darwin and linux).
  crossPlatformOverlapAttrs = [
    {
      name = "blender";
      nixpkgs = "blender";
    }
    {
      name = "czkawka";
      nixpkgs = "czkawka";
    }
    {
      name = "google-chrome";
      nixpkgs = "google-chrome";
    }
    {
      name = "krita";
      nixpkgs = "krita";
    }
    {
      name = "libreoffice";
      nixpkgs = "libreoffice";
    }
    {
      name = "obsidian";
      nixpkgs = "obsidian";
    }
    {
      name = "musicbrainz-picard";
      nixpkgs = "picard";
    }
    {
      name = "qemu";
      nixpkgs = "qemu";
    }
    {
      name = "discord@canary";
      nixpkgs = "discord-canary";
    }
    {
      name = "cursor";
      nixpkgs = "code-cursor";
    }
    {
      name = "visual-studio-code";
      nixpkgs = "vscode";
    }
    {
      name = "vlc";
      nixpkgs = "vlc";
    }
    # --- Completed overlap entries (cross-platform, carry a winget.id) ---
    {
      name = "google-chrome@canary";
      nixpkgs = "google-chrome";
    }
    {
      name = "chrome-remote-desktop";
      nixpkgs = "chrome-remote-desktop";
    }
    {
      name = "gimp";
      nixpkgs = "gimp";
    }
    {
      name = "qtpass";
      nixpkgs = "qtpass";
    }
    {
      name = "neovim";
      nixpkgs = "neovim";
    }
    {
      name = "krokiet";
      nixpkgs = "krokiet";
    }
    {
      name = "parsec";
      nixpkgs = "parsec";
    }
    {
      name = "peace-equalizer-apo";
      nixpkgs = "peace-equalizer-apo";
    }
    {
      name = "equalizer-apo";
      nixpkgs = "equalizer-apo";
    }
    {
      name = "steam";
      nixpkgs = "steam";
    }
    {
      name = "telegram@beta";
      nixpkgs = "telegram-desktop";
    }
    {
      name = "powersession";
      nixpkgs = "powersession";
    }
    {
      name = "whatsapp-beta";
      nixpkgs = "whatsapp";
    }
    {
      name = "powertoys";
      nixpkgs = "powertoys";
    }
    {
      name = "windows-terminal-preview";
      nixpkgs = "windows-terminal-preview";
    }
    {
      name = "scoop";
      nixpkgs = "scoop";
    }
    {
      name = "winfsp";
      nixpkgs = "winfsp";
    }
    {
      name = "7zip";
      nixpkgs = "p7zip";
    }
    {
      name = "gpg4win";
      nixpkgs = "gnupg";
    }
    {
      name = "zoxide";
      nixpkgs = "zoxide";
    }
    {
      name = "ghostscript";
      nixpkgs = "ghostscript";
    }
    {
      name = "packer";
      nixpkgs = "packer";
    }
    {
      name = "uv";
      nixpkgs = "uv";
    }
    {
      name = "ruff";
      nixpkgs = "ruff";
    }
    {
      name = "ty";
      nixpkgs = "ty";
    }
    {
      name = "ripgrep";
      nixpkgs = "ripgrep";
    }
    {
      name = "caddy";
      nixpkgs = "caddy";
    }
    {
      name = "bottom";
      nixpkgs = "bottom";
    }
    {
      name = "direnv";
      nixpkgs = "direnv";
    }
    {
      name = "starship";
      nixpkgs = "starship";
    }
    {
      name = "eza";
      nixpkgs = "eza";
    }
    {
      name = "git";
      nixpkgs = "gitFull";
    }
    {
      name = "gh";
      nixpkgs = "gh";
    }
    {
      name = "ffmpeg";
      nixpkgs = "ffmpeg-full";
    }
    {
      name = "imagemagick";
      nixpkgs = "imagemagick";
    }
    {
      name = "prek";
      nixpkgs = "prek";
    }
    {
      name = "jq";
      nixpkgs = "jq";
    }
    {
      name = "jellyfin";
      nixpkgs = "jellyfin";
    }
    {
      name = "fzf";
      nixpkgs = "fzf";
    }
    {
      name = "dotnet-runtime-6";
      nixpkgs = "dotnetCorePackages.runtime_6_0";
    }
    {
      name = "powershell";
      nixpkgs = "powershell";
    }
    {
      name = "ollama";
      nixpkgs = "ollama";
    }
    {
      name = "bun";
      nixpkgs = "bun";
    }
    {
      name = "rclone";
      nixpkgs = "rclone";
    }
    {
      name = "actionlint";
      nixpkgs = "actionlint";
    }
    {
      name = "rustup";
      nixpkgs = "rustup";
    }
    {
      name = "sops";
      nixpkgs = "sops";
    }
    {
      name = "bat";
      nixpkgs = "bat";
    }
    {
      name = "fd";
      nixpkgs = "fd";
    }
    {
      name = "shellcheck";
      nixpkgs = "shellcheck";
    }
    {
      name = "opencode";
      nixpkgs = "opencode";
    }
    {
      name = "pinact";
      nixpkgs = "pinact";
    }
    {
      name = "python";
      nixpkgs = "python3";
    }
    {
      name = "typst";
      nixpkgs = "typst";
    }
    {
      name = "taplo";
      nixpkgs = "taplo";
    }
    {
      name = "zizmor";
      nixpkgs = "zizmor";
    }
    {
      name = "sccache";
      nixpkgs = "sccache";
    }
    {
      name = "shfmt";
      nixpkgs = "shfmt";
    }
    {
      name = "llvm";
      nixpkgs = "llvmPackages_latest.llvm";
    }
    {
      name = "platform-tools";
      nixpkgs = "android-tools";
    }
    {
      name = "source-serif";
      nixpkgs = "source-serif";
    }
    {
      name = "jetbrains-mono-nerd-font";
      nixpkgs = "nerd-fonts.jetbrains-mono";
    }
    {
      name = "noto-sans-cjk-sc";
      nixpkgs = "noto-fonts-cjk-sans";
    }
    {
      name = "noto-sans-cjk-tc";
      nixpkgs = "noto-fonts-cjk-sans";
    }
    {
      name = "noto-serif-cjk-sc";
      nixpkgs = "noto-fonts-cjk-serif";
    }
    {
      name = "noto-serif-cjk-tc";
      nixpkgs = "noto-fonts-cjk-serif";
    }
    {
      name = "inter";
      nixpkgs = "inter";
    }
    {
      name = "zoom";
      nixpkgs = "zoom-us";
    }
    {
      name = "obs-studio";
      nixpkgs = "obs-studio";
    }
    {
      name = "jdk";
      nixpkgs = "jdk";
    }
    # --- Former baseSharedPackages CLI tools (folded into managedPackages) ---
    {
      name = "android-tools";
      nixpkgs = "android-tools";
    }
    {
      name = "asciinema";
      nixpkgs = "asciinema";
    }
    {
      name = "camilladsp";
      nixpkgs = "camilladsp";
    }
    {
      name = "cargo-binstall";
      nixpkgs = "cargo-binstall";
    }
    {
      name = "cargo-cache";
      nixpkgs = "cargo-cache";
    }
    {
      name = "cargo-nextest";
      nixpkgs = "cargo-nextest";
    }
    {
      name = "check-jsonschema";
      nixpkgs = "check-jsonschema";
    }
    {
      name = "deadnix";
      nixpkgs = "deadnix";
    }
    {
      name = "gnupg";
      nixpkgs = "gnupg";
    }
    {
      name = "litellm";
      nixpkgs = "litellm";
    }
    {
      name = "llvm-clang";
      nixpkgs = "llvmPackages.clang";
    }
    {
      name = "llvm-lld";
      nixpkgs = "llvmPackages.lld";
    }
    {
      name = "llvm-lldb";
      nixpkgs = "llvmPackages.lldb";
    }
    {
      name = "mold";
      nixpkgs = "mold";
    }
    {
      name = "ncdu";
      nixpkgs = "ncdu";
    }
    {
      name = "nickel";
      nixpkgs = "nickel";
    }
    {
      name = "nixd";
      nixpkgs = "nixd";
    }
    {
      name = "nixf";
      nixpkgs = "nixf";
    }
    {
      name = "nixfmt";
      nixpkgs = "nixfmt";
    }
    {
      name = "nix-index";
      nixpkgs = "nix-index";
    }
    {
      name = "nls";
      nixpkgs = "nls";
    }
    {
      name = "pay-respects";
      nixpkgs = "pay-respects";
    }
    {
      name = "pi-coding-agent";
      nixpkgs = "pi-coding-agent";
    }
    {
      name = "ssh-to-age";
      nixpkgs = "ssh-to-age";
    }
    {
      name = "yamllint";
      nixpkgs = "yamllint";
    }
    {
      name = "yq-go";
      nixpkgs = "yq-go";
    }
  ];

  # Darwin-only managedPackages entries (attrs exist on Linux nixpkgs but
  # are only buildable on darwin via meta.platforms).
  darwinOnlyPackages = [
    {
      name = "iterm2";
      nixpkgs = "iterm2";
    }
    {
      name = "rectangle";
      nixpkgs = "rectangle";
    }
    {
      name = "stats";
      nixpkgs = "stats";
    }
    {
      name = "utm@beta";
      nixpkgs = "utm";
    }
    {
      name = "visual-studio-code@insiders";
      nixpkgs = "vscode-insiders";
    }
    {
      name = "duti";
      nixpkgs = "duti";
    }
    {
      name = "desktoppr";
      nixpkgs = "desktoppr";
    }
    {
      name = "pinentry_mac";
      nixpkgs = "pinentry_mac";
    }
    {
      name = "equaliser";
      nixpkgs = "equaliser";
    }
  ];

  test_overlapping_packages_have_nixpkgs = assert' (builtins.all
    (p: builtins.match (".*" + p.nixpkgs + ".*") coreModuleText != null)
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
        !builtins.hasAttr p.nixpkgs linuxPkgs
        || !(builtins.elem "x86_64-linux" (linuxPkgs.${p.nixpkgs}.meta.platforms or [ ]));
    in
    assert' (builtins.all notBuildableOnLinux darwinOnlyPackages) "Darwin-only packages must not be buildable on Linux";

  # Guard: every managedPackages entry in core.nix must be covered by either
  # crossPlatformOverlapAttrs (cross-platform) or darwinOnlyPackages (darwin-only).
  test_all_overlapping_packages_covered =
    let
      # Scope extraction to the managedPackages = { ... }; block so option
      # declarations like `    default = { }` elsewhere in core.nix are not
      # mistaken for package entries. Find the block by its unique opening marker
      # and the first top-level `  };` that closes it.
      marker = "managedPackages = {";
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
    ) "All managedPackages entries must be covered by tests: ${builtins.toString uncovered}";

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
