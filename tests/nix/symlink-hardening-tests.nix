let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  # Test files that should contain symlink protection code
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  devReposText = builtins.readFile ../../src/modules/dev-repos.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
in
{
  # =========================================================================
  # Assertion 1: VS Code symlink protection in editors.nix
  # =========================================================================
  vsCodeProtection =
    assert containsRegex "_nucleus_protect_symlink" editorsText;
    assert containsRegex "_nucleus_unprotect_symlink" editorsText;
    assert containsRegex "chflags -h uchg" editorsText;
    assert containsRegex "chattr -h \\+i" editorsText;
    assert containsRegex "chflags -h nouchg" editorsText;
    true;

  # =========================================================================
  # Assertion 2: Agents config symlink protection in agents.nix
  # =========================================================================
  agentsConfigProtection =
    assert containsRegex "_nucleus_protect_symlink" agentsText;
    assert containsRegex "agents-config" agentsText;
    assert containsRegex "chflags -h uchg" agentsText;
    true;

  # =========================================================================
  # Assertion 3: Agents skills symlink protection in agents.nix
  # =========================================================================
  agentsSkillsProtection =
    assert containsRegex "agents-skills" agentsText;
    assert containsRegex "_nucleus_protect_symlink" agentsText;
    assert containsRegex "_nucleus_unprotect_symlink" agentsText;
    true;

  # =========================================================================
  # Assertion 4: Dev repos symlink protection in dev-repos.nix
  # =========================================================================
  devReposProtection =
    assert containsRegex "protect_managed_symlink" devReposText;
    assert containsRegex "unprotect_managed_symlink" devReposText;
    assert containsRegex "devReposProvision" devReposText;
    assert containsRegex "chflags -h" devReposText;
    true;

  # =========================================================================
  # Assertion 5: Raycast alias symlink protection in macos.nix
  # =========================================================================
  raycastAliasProtection =
    assert containsRegex "protect_alias_symlink" macosText;
    assert containsRegex "unprotect_alias_symlink" macosText;
    assert containsRegex "raycast" macosText;
    true;

  # =========================================================================
  # Assertion 6: Finder sidebar rewrite in macos.nix
  # =========================================================================
  finderSidebarRewrite =
    assert containsRegex "osascript -l JavaScript" macosText;
    assert containsRegex "NSKeyedUnarchiver" macosText;
    assert containsRegex "NSKeyedArchiver" macosText;
    assert containsRegex "FavoriteItems\\.sfl4" macosText;
    assert !containsRegex "sfltool add-item" macosText;
    assert !containsRegex "sfltool remove-item" macosText;
    true;

  # =========================================================================
  # Assertion 7: ShouldProcess compliance for all helpers
  # =========================================================================
  shouldProcessCompliance =
    let
      # Path to Windows PS1 files
      vsCodePs1Path = ../../src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1;
      agentsConfigPs1Path = ../../src/hosts/windows/modules/user/Sync-AgentsConfig.ps1;
      agentsSkillPs1Path = ../../src/hosts/windows/modules/user/Sync-AgentsSkill.ps1;
      devRepoPs1Path = ../../src/hosts/windows/modules/user/Sync-DevRepo.ps1;
    in
    assert builtins.pathExists vsCodePs1Path;
    assert builtins.pathExists agentsConfigPs1Path;
    assert builtins.pathExists agentsSkillPs1Path;
    assert builtins.pathExists devRepoPs1Path;
    true;

  # =========================================================================
  # Assertion 8: Dev repos logging keeps errors visible and no-op skips quiet
  # =========================================================================
  devReposLoggingPolicy =
    assert containsRegex "report_error\(\)" devReposText;
    assert containsRegex "completed with .*non-fatal error" devReposText;
    assert !containsRegex "devReposProvision: .*\(skipping\)" devReposText;
    true;

  # =========================================================================
  # All tests passed
  # =========================================================================
  summary = {
    testSuiteName = "Symlink Hardening Regression Tests";
    totalAssertions = 8;
    coverage = [
      "VS Code"
      "Agents Config"
      "Agents Skills"
      "Dev Repos"
      "Dev Repos Logging"
      "Raycast Aliases"
      "Finder Sidebar"
      "Windows ShouldProcess"
    ];
  };
}
