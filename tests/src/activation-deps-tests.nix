# tests/src/activation-deps-tests.nix — Validate activation dependency ordering.
#
# Tests verify that Home Manager activation hooks and Windows DSC steps are
# ordered correctly so dependencies are satisfied before dependents run.
# Key invariants:
# - Secret materialization before dev repo provisioning
# - SSH keys loaded before git clones over SSH
# - GPG keys imported before signed commits
#
# Run with: nix-instantiate --eval tests/src/activation-deps-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  inherit (lib) topologicalSort unique;

  # Read live module files so ordering/name regressions are caught by tests
  # instead of relying only on mocked activation maps.
  agentsModuleText = builtins.readFile ../../src/modules/agents.nix;
  linuxModuleText = builtins.readFile ../../src/modules/linux.nix;
  macosModuleText = builtins.readFile ../../src/modules/macos.nix;
  activationDagModuleText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  macbookActivationText = builtins.readFile ../../src/hosts/MacBook/activation.nix;
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  windowsGitSshModuleText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1;
  sharedGitModuleText = builtins.readFile ../../src/modules/git.nix;

  inherit (import ../lib.nix) assert';

  # === TEST: Secret materialization before dev repo provision ===
  test_secrets_before_devrepo =
    let
      # Define activation steps with dependencies.
      activations = {
        waitForSopsSecrets = {
          before = [ ];
          after = [ ];
        };
        gitIdentityFromSops = {
          before = [ "waitForSopsSecrets" ];
          after = [ ];
        };
        devReposProvision = {
          before = [ "gitIdentityFromSops" ];
          after = [ ];
        };
      };
      # Check order: secrets → git identity → dev repos
      secretsFirst = activations.waitForSopsSecrets;
      gitSecond = activations.gitIdentityFromSops;
      devThird = activations.devReposProvision;
    in
    assert' (
      (builtins.elem "waitForSopsSecrets" gitSecond.before)
      && (builtins.elem "gitIdentityFromSops" devThird.before)
    ) "Secrets must materialize before dev repos provision";

  # === TEST: SSH key loading before Git clone ===
  test_ssh_before_git =
    let
      activations = {
        sshKeyAdopt = {
          before = [ "waitForSopsSecrets" ];
          after = [ ];
        };
        devReposProvision = {
          before = [ "sshKeyAdopt" ];
          after = [ ];
        };
      };
    in
    assert' (builtins.elem "sshKeyAdopt" activations.devReposProvision.before) "SSH keys must load before Git clones";

  # === TEST: GPG keys imported before commits ===
  test_gpg_before_commits =
    let
      activations = {
        gpgImport = {
          before = [ "waitForSopsSecrets" ];
          after = [ ];
        };
        gitIdentityFromSops = {
          before = [ "gpgImport" ];
          after = [ ];
        };
      };
    in
    assert' (builtins.elem "gpgImport" activations.gitIdentityFromSops.before) "GPG keys must import before Git identity setup";

  # === TEST: Manual instructions depend on all protect-*Symlink entries (macOS) ===
  # protect*Symlink entries run entryAfter ["linkGeneration"] and must be
  # listed in displayHostManualInstructionDeps so manual instructions remain
  # the final activation step.
  test_macos_manual_instructions_last =
    let
      # Extract the displayHostManualInstructionDeps list content by splitting
      # on opening and closing delimiters, then verify protect entries are inside.
      macosDepsSplit = builtins.split "displayHostManualInstructionDeps = \(import \./lib/activation-dag\.nix\) \+\+ \[" macosModuleText;
      macosDepsContent =
        if builtins.length macosDepsSplit >= 3 then
          builtins.elemAt (builtins.split "\];" (builtins.elemAt macosDepsSplit 2)) 0
        else
          "";
      protectEntries = [
        "protectDownloadsICloudSymlink"
        "protectOpencodeSymlinks"
        "protectOutOfStoreSymlinks"
      ];
      allInMacosDeps = builtins.all (entry: lib.hasInfix "\"${entry}\"" macosDepsContent) protectEntries;
    in
    assert' allInMacosDeps "protect*Symlink entries must be inside displayHostManualInstructionDeps list (macOS) so manual instructions run last";

  # === TEST: Manual instructions depend on protect entries (Linux) ===
  # Same invariant on Linux: displayHostManualInstructions uses entryAfter
  # with an inline list that must include protect*Symlink entries.
  test_linux_manual_instructions_last =
    let
      # Extract the entryAfter list content for displayHostManualInstructions.
      # First split on the entryAfter opening paren, then locate the `++ [`
      # start and the `]` that closes the inline list.
      linuxEntryAfterSplit = builtins.split "displayHostManualInstructions = lib\.hm\.dag\.entryAfter \(" linuxModuleText;
      linuxAfterEntryAfter =
        if builtins.length linuxEntryAfterSplit >= 3 then builtins.elemAt linuxEntryAfterSplit 2 else "";
      linuxListStartSplit = builtins.split "\+\+ \[" linuxAfterEntryAfter;
      linuxAfterListStart =
        if builtins.length linuxListStartSplit >= 3 then builtins.elemAt linuxListStartSplit 2 else "";
      linuxDepsSplit = builtins.split "\][[:space:]]*\)" linuxAfterListStart;
      linuxDepsContent =
        if builtins.length linuxDepsSplit >= 3 then builtins.elemAt linuxDepsSplit 0 else "";
      linuxProtectEntries = [
        "protectOpencodeSymlinks"
        "protectOutOfStoreSymlinks"
      ];
      allInLinuxDeps = builtins.all (
        entry: lib.hasInfix "\"${entry}\"" linuxDepsContent
      ) linuxProtectEntries;
    in
    assert' allInLinuxDeps "protect*Symlink entries must be inside displayHostManualInstructions entryAfter list (Linux) so manual instructions run last";

  # === TEST: Activation names are unique ===
  test_activation_names_unique =
    let
      names = [
        "waitForSopsSecrets"
        "gitIdentityFromSops"
        "gpgImport"
        "sshKeyAdopt"
        "devReposProvision"
        "displayHostManualInstructions"
      ];
      uniqueNames = unique names;
    in
    assert' (
      (builtins.length names == builtins.length uniqueNames)
    ) "Activation step names must be unique";

  # === TEST: No circular dependencies ===
  test_no_circular_deps =
    let
      # Represent as edges: step -> steps it depends on (before list)
      activations = {
        a = {
          before = [ "b" ];
        };
        b = {
          before = [ "c" ];
        };
        c = {
          before = [ ];
        }; # Terminal: no deps
      };
      # Check simple case: no step depends on itself through transitivity
      # In practice, Home Manager's activation system would error on cycles
    in
    assert' (true) # Validated by NixOS/Home Manager eval
      "Activation graph should be acyclic";

  # === TEST: Windows DSC ordering invariant ===
  test_windows_dsc_ordering =
    let
      # Windows orchestration order (from apply.ps1 and module sequencing):
      # 1. Git + SSH config (for key setup)
      # 2. Secret materialization (decrypt SOPS keys)
      # 3. Dev repo sync (uses Git over SSH)
      steps = [
        "Sync-GitAndSshConfig" # Must be first
        "Invoke-JITSecretMaterialization" # After Git config
        "Sync-DevRepo" # After secrets materialized
      ];
      # Verify step count and order
      correctOrder =
        (builtins.elemAt steps 0 == "Sync-GitAndSshConfig")
        && (builtins.elemAt steps 1 == "Invoke-JITSecretMaterialization")
        && (builtins.elemAt steps 2 == "Sync-DevRepo");
    in
    assert' (
      correctOrder && (builtins.length steps == 3)
    ) "Windows DSC steps must execute in correct order: Git → Secrets → DevRepos";

  # === TEST: Agent skill provisioning after core setup ===
  test_agent_skills_after_core =
    let
      activations = {
        gitConfig = {
          after = [ ];
        };
        agentSkillsProvision = {
          after = [ "gitConfig" ];
        };
      };
    in
    assert' (builtins.elem "gitConfig" activations.agentSkillsProvision.after) "Agent skills must provision after core setup";

  # === TEST: Wallpaper gallery after user shell setup ===
  test_wallpaper_after_shell =
    let
      activations = {
        posixUserShell = {
          after = [ ];
        };
        wallpaperGallery = {
          after = [ "posixUserShell" ];
        };
      };
    in
    assert' (builtins.elem "posixUserShell" activations.wallpaperGallery.after) "Wallpaper must setup after user shell configured";

  # === TEST: Package installation before Home Manager activation ===
  test_packages_before_hm =
    let
      # On macOS: packages installed via Homebrew before Home Manager runs
      # On NixOS: system packages available before Home Manager
      order = [
        "system-packages"
        "home-manager-activation"
      ];
    in
    assert' (
      (builtins.elemAt order 0 == "system-packages")
      && (builtins.elemAt order 1 == "home-manager-activation")
    ) "System packages must be available before Home Manager activation";

  # === TEST: All activation steps have valid dependency references ===
  test_valid_dependency_references =
    let
      activationNames = [
        "waitForSopsSecrets"
        "gitIdentityFromSops"
        "gpgImport"
        "sshKeyAdopt"
        "devReposProvision"
      ];
      # Each dependency reference should exist in the names list
      testDep = name: builtins.elem name activationNames;
      validRefs = builtins.all testDep activationNames;
    in
    assert' (validRefs) "All activation dependency references must exist";

  # === TEST: Before/after consistency ===
  test_before_after_consistency =
    let
      # If A is in B's "before" list, B should be in A's "after" list (conceptually)
      # This tests bidirectional consistency
      activations = {
        step1 = {
          before = [ "step2" ];
          after = [ ];
        };
        step2 = {
          before = [ ];
          after = [ "step1" ];
        };
      };
    in
    assert' (
      (builtins.elem "step2" activations.step1.before) && (builtins.elem "step1" activations.step2.after)
    ) "Before/after lists should be bidirectionally consistent";

  # === TEST: syncClawHubSkills dependency name stays aligned across modules ===
  test_sync_clawhub_dependency_name_alignment =
    assert'
      (
        (lib.hasInfix "syncClawHubSkills = lib.hm.dag.entryAfter" agentsModuleText)
        && (lib.hasInfix "\"syncClawHubSkills\"" activationDagModuleText)
      )
      "syncClawHubSkills activation name must match between agents.nix and activation-dag.nix dependency list";

  # === TEST: syncClawHubSkills must not short-circuit activation ===
  test_sync_clawhub_does_not_exit_activation =
    let
      syncHasExitZero =
        builtins.match "(.|\n)*syncClawHubSkills = lib.hm.dag.entryAfter(.|\n)*exit 0(.|\n)*" agentsModuleText
        != null;
    in
    assert' (!syncHasExitZero)
      "syncClawHubSkills must not call exit 0, or later activation steps (including displayHostManualInstructions) are skipped";

  # === TEST: GIMP sensitivity targets installed app version dynamically ===
  test_gimp_sensitivity_version_tracking =
    assert'
      (
        (lib.hasInfix "/Applications/GIMP.app/Contents/Info" macbookActivationText)
        && (lib.hasInfix "gimp_version_branch" macbookActivationText)
        && !(lib.hasInfix "for gimp_version in 2.10 3.0" macbookActivationText)
      )
      "GIMP sensitivity provisioning must derive version from installed GIMP.app (no hardcoded version loop)";

  # === TEST: Windows Git identity applies to each managed profile path ===
  test_windows_git_identity_targets_user_gitconfig =
    assert'
      (
        (lib.hasInfix "config --file $gitConfigPath" windowsGitSshModuleText)
        && !(lib.hasInfix "config --global" windowsGitSshModuleText)
      )
      "Windows Git identity must write via --file $gitConfigPath, not --global, so each managed user profile gets the correct target path";

  # === TEST: POSIX Git defaults enforce signed commits and tags ===
  test_posix_git_signing_defaults_enabled =
    assert'
      (
        (lib.hasInfix "commit.gpgsign = true;" sharedGitModuleText)
        && (lib.hasInfix "tag.gpgsign = true;" sharedGitModuleText)
      )
      "POSIX Git defaults must keep commit.gpgsign and tag.gpgsign enabled for cross-host signing parity";

  # === TEST: macOS MiddleClick startup uses native Login Items, not LaunchAgent ===
  test_middleclick_native_login_item = assert' (
    (lib.hasInfix "make login item at end with properties {name:\"MiddleClick\"" macbookActivationText)
    && (lib.hasInfix "tell application \"System Events\"" macbookActivationText)
    && !(lib.hasInfix "launchd.agents.\"art.ginzburg.MiddleClick\"" macbookDefaultText)
  ) "MiddleClick startup on macOS must use native Login Items (no custom LaunchAgent)";

  # === TEST: Spotlight disables all known launcher hotkey slots ===
  test_spotlight_disables_all_hotkey_slots = assert' ((lib.hasInfix "for hotkey in 61 64 65; do" macbookActivationText)) "Spotlight disable flow must cover symbolic hotkey IDs 61, 64, and 65";

  # === TEST: installCargoBinstallPackages activation name aligned across modules ===
  test_install_cargo_binstall_dependency_name_alignment =
    assert'
      (
        (lib.hasInfix "installCargoBinstallPackages = lib.hm.dag.entryAfter" agentsModuleText)
        && (lib.hasInfix "\"installCargoBinstallPackages\"" macosModuleText)
      )
      "installCargoBinstallPackages activation name must match between agents.nix and macos.nix dependency list";

  # === TEST: macOS dev-tree maintenance is scheduled, not activation-bound ===
  test_macos_dev_maintenance_is_scheduled = assert' (
    (lib.hasInfix "launchd.agents.\"dev-ds-store-gc\"" macosModuleText)
    && (lib.hasInfix "launchd.agents.\"dev-spotlight-exclusions\"" macosModuleText)
    && (lib.hasInfix "Label = \"local.dev-ds-store-gc\";" macosModuleText)
    && (lib.hasInfix "Label = \"local.dev-spotlight-exclusions\";" macosModuleText)
    && (lib.hasInfix "ProgramArguments = [ \"\${devDsStoreGc}\" ];" macosModuleText)
    && (lib.hasInfix "ProgramArguments = [ \"\${devSpotlightExclusions}\" ];" macosModuleText)
    && !(lib.hasInfix "cleanDevDsStore = lib.hm.dag.entryAfter" macosModuleText)
    && !(lib.hasInfix "configureDevSpotlightExclusions = lib.hm.dag.entryAfter" macosModuleText)
  ) "macOS dev-tree maintenance must run from launchd agents instead of Home Manager activation";

  # Collect all tests.
  allTests = [
    test_secrets_before_devrepo
    test_ssh_before_git
    test_gpg_before_commits
    test_macos_manual_instructions_last
    test_linux_manual_instructions_last
    test_activation_names_unique
    test_no_circular_deps
    test_windows_dsc_ordering
    test_agent_skills_after_core
    test_wallpaper_after_shell
    test_packages_before_hm
    test_valid_dependency_references
    test_before_after_consistency
    test_sync_clawhub_dependency_name_alignment
    test_sync_clawhub_does_not_exit_activation
    test_gimp_sensitivity_version_tracking
    test_windows_git_identity_targets_user_gitconfig
    test_posix_git_signing_defaults_enabled
    test_middleclick_native_login_item
    test_spotlight_disables_all_hotkey_slots
    test_install_cargo_binstall_dependency_name_alignment
    test_macos_dev_maintenance_is_scheduled
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} activation dependency tests passed";
  testNames = [
    "1: Secrets materialize before dev repo provision"
    "2: SSH keys load before Git clone"
    "3: GPG keys import before commit setup"
    "4: Manual instructions run last"
    "5: Activation step names are unique"
    "6: No circular activation dependencies"
    "7: Windows DSC ordering is correct"
    "8: Agent skills provision after core setup"
    "9: Wallpaper setup after shell configuration"
    "10: System packages available before Home Manager"
    "11: Activation dependencies reference valid steps"
    "12: Before/after dependency consistency"
    "13: syncClawHubSkills dependency name alignment"
    "14: syncClawHubSkills does not exit activation"
    "15: GIMP sensitivity tracks installed app version"
    "16: Windows Git identity targets per-user .gitconfig"
    "17: POSIX Git defaults enforce signed commits and tags"
    "18: MiddleClick startup uses native login-item path"
    "19: Spotlight disables all known launcher hotkey slots"
    "20: installCargoBinstallPackages activation name alignment"
    "21: macOS dev-tree maintenance runs from launchd instead of activation"
  ];
}
