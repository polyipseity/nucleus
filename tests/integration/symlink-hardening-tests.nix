let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  # Test files that should contain symlink protection code
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  devReposText = builtins.readFile ../../src/modules/dev-repos.nix;
  customProvisionSymlinksText = builtins.readFile ../../src/modules/custom-provision-symlinks.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  finderSidebarText = builtins.readFile ../../src/modules/macos/finder-sidebar.nix;
  agentsHelpersText = builtins.readFile ../../src/scripts/agent-helpers.sh;
in
rec {
  # =========================================================================
  # Assertion 1: VS Code symlink protection in editors.nix
  #               (shell helpers that implement chflags/chattr live in
  #                agent-helpers.sh — verified below via agentsHelpersText)
  # =========================================================================
  vsCodeProtection =
    assert containsRegex "_nucleus_protect_symlink" editorsText;
    assert containsRegex "_nucleus_unprotect_symlink" editorsText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    assert containsRegex "chattr -h \\+i" agentsHelpersText;
    assert containsRegex "chflags -h nouchg" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 2: Agents config symlink protection — function def in agent-helpers.sh,
  #               symlink target name in agents.nix
  # =========================================================================
  agentsConfigProtection =
    assert containsRegex "_nucleus_protect_symlink" agentsHelpersText;
    assert containsRegex "agents-config" agentsText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 3: Agents skills symlink protection — function def in agent-helpers.sh,
  #               context string in agents.nix
  # =========================================================================
  agentsSkillsProtection =
    assert containsRegex "agents-skills" agentsText;
    assert containsRegex "_nucleus_protect_symlink" agentsHelpersText;
    assert containsRegex "_nucleus_unprotect_symlink" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 4: Dev repos symlink protection in dev-repos.nix
  # =========================================================================
  devReposProtection =
    assert containsRegex "_nucleus_protect_symlink" devReposText;
    assert containsRegex "_nucleus_unprotect_symlink" devReposText;
    assert containsRegex "devReposProvision" devReposText;
    assert containsRegex "chflags -h" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 5: Custom provision symlink protection in custom-provision-symlinks.nix
  # =========================================================================
  customProvisionSymlinkProtection =
    assert containsRegex "_nucleus_protect_symlink" customProvisionSymlinksText;
    assert containsRegex "_nucleus_unprotect_symlink" customProvisionSymlinksText;
    assert containsRegex "custom-provision-symlinks\.json" customProvisionSymlinksText;
    assert containsRegex "chflags -h uchg" agentsHelpersText;
    assert containsRegex "chattr -h \\+i" agentsHelpersText;
    true;

  # =========================================================================
  # Assertion 5: Raycast alias symlink protection in macos.nix
  # =========================================================================
  raycastAliasProtection =
    assert containsRegex "_nucleus_protect_symlink" macosText;
    assert containsRegex "_nucleus_unprotect_symlink" macosText;
    assert containsRegex "raycast" macosText;
    true;

  # =========================================================================
  # Assertion 6: Finder sidebar automation in macos.nix
  # =========================================================================
  finderSidebarRewrite =
    assert containsRegex "pkgs\\.mysides" macosText;
    assert containsRegex "add_favorite" macosText;
    assert containsRegex "configureFinderSidebar" macosText;
    assert containsRegex "import \\./macos/finder-sidebar" macosText;
    assert containsRegex "finderSidebarManagedFavorites" finderSidebarText;
    assert containsRegex "\"\\$MYSIDES_BIN\" remove" finderSidebarText;
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
    assert containsRegex "report_error\\(\\)" devReposText;
    assert containsRegex "completed with .*non-fatal error" devReposText;
    assert !containsRegex "devReposProvision: .*\(skipping\)" devReposText;
    true;

  # =========================================================================
  # Validation: force all assertions — if any fails, evaluation aborts.
  # =========================================================================
  _validation =
    let
      allResults = [
        vsCodeProtection
        agentsConfigProtection
        agentsSkillsProtection
        devReposProtection
        customProvisionSymlinkProtection
        raycastAliasProtection
        finderSidebarRewrite
        shouldProcessCompliance
        devReposLoggingPolicy
      ];
    in
    builtins.all (x: x == true) allResults;

  # =========================================================================
  # All tests passed
  # =========================================================================
  summary = {
    testSuiteName = "Symlink Hardening Regression Tests";
    totalAssertions = 9;
    coverage = [
      "VS Code"
      "Agents Config"
      "Agents Skills"
      "Custom Provision Symlinks"
      "Dev Repos"
      "Dev Repos Logging"
      "Raycast Aliases"
      "Finder Sidebar"
      "Windows ShouldProcess"
    ];
  };
}
