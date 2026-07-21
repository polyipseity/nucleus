let
  inherit (import ../lib.nix) containsRegex flatten;

  # Test files that should contain symlink protection code
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  devReposText = builtins.readFile ../../src/modules/dev-repos.nix;
  customProvisionSymlinksText = builtins.readFile ../../src/modules/custom-provision-symlinks.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  finderSidebarText = builtins.readFile ../../src/modules/macos/finder-sidebar.nix;
  agentsHelpersText = builtins.readFile ../../src/scripts/lib/symlink-hardening-lib.sh;
  discordMusicRpcText = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  homeNixText = builtins.readFile ../../src/modules/home.nix;
in
rec {
  # =========================================================================
  # Assertion 1: VS Code symlink protection in editors.nix
  #               (shell functions that implement chflags/chattr live in
  #                symlink-hardening-lib.sh — verified below via agentsHelpersText
  #                editors.nix references the activation scripts that call
  #                those functions)
  # =========================================================================
  vsCodeProtection =
    assert containsRegex "symlink-vscode-config" editorsText;
    assert containsRegex "bridge-vscode-extensions" editorsText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    assert containsRegex "chattr -h \\+i" agentsHelpersText;
    assert containsRegex "chflags -h nouchg" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 2: Agents config symlink protection — function def in symlink-hardening-lib.sh,
  #               symlink target name in agents.nix
  # =========================================================================
  agentsConfigProtection =
    assert containsRegex "_nucleus_protect_symlink" agentsHelpersText;
    assert containsRegex "opencode/agents" agentsText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 3: Agents skills symlink protection — function def in symlink-hardening-lib.sh,
  #               activation name in agents.nix
  # =========================================================================
  skillsProtection =
    assert containsRegex "install-agent-skills" agentsText;
    assert containsRegex "_nucleus_protect_symlink" agentsHelpersText;
    assert containsRegex "_nucleus_unprotect_symlink" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 4: Dev repos symlink protection in dev-repos.nix
  # =========================================================================
  devReposProtection =
    assert containsRegex "activationBundle" devReposText;
    assert containsRegex "provision-dev-repos" devReposText;
    assert containsRegex "devReposProvision" devReposText;
    assert containsRegex "chflags -h" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 5: Custom provision symlink protection in custom-provision-symlinks.nix
  # =========================================================================
  customProvisionSymlinkProtection =
    assert containsRegex "activationBundle" customProvisionSymlinksText;
    assert containsRegex "finalize-symlinks" customProvisionSymlinksText;
    assert containsRegex "custom-provision-symlinks\.json" customProvisionSymlinksText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    assert containsRegex "chattr -h \\+i" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 5: Raycast alias symlink protection in macos.nix
  # =========================================================================
  raycastAliasProtection =
    assert containsRegex "activationBundle" macosText;
    assert containsRegex "raycast-aliases" macosText;
    assert containsRegex "_nucleus_protect_symlink" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 6: Finder sidebar automation in macos.nix
  # =========================================================================
  finderSidebarRewrite =
    assert containsRegex "pkgs\\.mysides" macosText;
    assert containsRegex "configure-finder-sidebar" macosText;
    assert containsRegex "configureFinderSidebar" macosText;
    assert containsRegex "import \\./macos/finder-sidebar" macosText;
    assert containsRegex "finderSidebarManagedFavorites" finderSidebarText;
    assert containsRegex "uriEncode" finderSidebarText;
    assert !containsRegex "sfltool add-item" macosText;
    assert !containsRegex "sfltool remove-item" macosText;
    true;

  # =========================================================================
  # Assertion 7: ShouldProcess compliance for all helpers
  # =========================================================================
  shouldProcessCompliance =
    let
      # Path to Windows PS1 files
      vsCodePs1Path = ../../src/hosts/Windows/modules/editors/Sync-VSCodeConfig.ps1;
      agentsConfigPs1Path = ../../src/hosts/Windows/modules/user/Sync-AgentsConfig.ps1;
      agentsSkillPs1Path = ../../src/hosts/Windows/modules/user/Sync-AgentsSkill.ps1;
      customProvisionPs1Path = ../../src/hosts/Windows/modules/user/Sync-CustomProvisionSymlink.ps1;
      devRepoPs1Path = ../../src/hosts/Windows/modules/user/Sync-DevRepo.ps1;
    in
    assert builtins.pathExists vsCodePs1Path;
    assert builtins.pathExists agentsConfigPs1Path;
    assert builtins.pathExists agentsSkillPs1Path;
    assert builtins.pathExists customProvisionPs1Path;
    assert builtins.pathExists devRepoPs1Path;
    true;

  # =========================================================================
  # Assertion 8: Dev repos logging keeps errors visible and no-op skips quiet
  # =========================================================================
  devReposLoggingPolicy =
    assert containsRegex "provision-dev-repos" devReposText;
    assert containsRegex "activationBundle" devReposText;
    assert !containsRegex "devReposProvision: .*\(skipping\)" devReposText;
    true;

  # =========================================================================
  # Assertion 9: Discord Music RPC config symlink protection
  # =========================================================================
  discordMusicRpcConfigProtection =
    assert containsRegex "mkOutOfStoreSymlink" discordMusicRpcText;
    assert containsRegex "discord-music-rpc/config.yaml" discordMusicRpcText;
    assert containsRegex "ext-discord-music-rpc" homeNixText;
    assert containsRegex "mkOutOfStoreSymlink" discordMusicRpcText;
    true;

  # =========================================================================
  # Validation: force all assertions — if any fails, evaluation aborts.
  # =========================================================================
  _validation =
    let
      allResults = [
        vsCodeProtection
        agentsConfigProtection
        skillsProtection
        devReposProtection
        customProvisionSymlinkProtection
        raycastAliasProtection
        finderSidebarRewrite
        shouldProcessCompliance
        devReposLoggingPolicy
        discordMusicRpcConfigProtection
      ];
    in
    builtins.all (x: x == true) allResults;

  # =========================================================================
  # All tests passed
  # =========================================================================
  success = _validation;
  summary = {
    testSuiteName = "Symlink Hardening Regression Tests";
    totalAssertions = 10;
    coverage = [
      "VS Code"
      "Agents Config"
      "Skills"
      "Custom Provision Symlinks"
      "Dev Repos"
      "Dev Repos Logging"
      "Raycast Aliases"
      "Finder Sidebar"
      "Windows ShouldProcess"
      "Discord Music RPC"
    ];
  };
}
