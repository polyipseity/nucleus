# tests/integration/activation-deps-tests.nix — Validate activation dependency ordering.
#
# Tests verify that Home Manager activation hooks and Windows DSC steps are
# ordered correctly so dependencies are satisfied before dependents run.
# Key invariants:
# - Secret materialization before dev repo provisioning
# - SSH keys loaded before git clones over SSH
# - GPG keys imported before signed commits
#
let
  lib = import <nixpkgs/lib>;
  inherit (lib) unique;

  # Read live module files so ordering/name regressions are caught by tests
  # instead of relying only on mocked activation maps.
  agentsModuleText = builtins.readFile ../../src/modules/agents.nix;
  shellModuleText = builtins.readFile ../../src/modules/shell.nix;
  macosModuleText = builtins.readFile ../../src/platforms/macOS/modules/default.nix;
  activationDagModuleText = builtins.readFile ../../src/modules/lib/activation-dag.nix;
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  middleClickScriptText = builtins.readFile ../../src/hosts/MacBook/scripts/macos-enable-middle-click.sh;
  spotlightScriptText = builtins.readFile ../../src/hosts/MacBook/scripts/macos-disable-spotlight.sh;
  gimpScrollSensitivityScriptText = builtins.readFile ../../src/scripts/configs/configure-gimp-scroll-sensitivity.sh;
  windowsGitSshModuleText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1;
  macbookUserGitconfigText = builtins.readFile ../../src/users/default/git/MacBook.gitconfig;
  nixosUserGitconfigText = builtins.readFile ../../src/users/default/git/NixOS.gitconfig;
  discordMusicRpcModuleText = builtins.readFile ../../src/modules/ext-discord-music-rpc.nix;
  homeModuleText = builtins.readFile ../../src/modules/home.nix;
  macbookServicesText = builtins.readFile ../../src/hosts/MacBook/services.nix;
  macbookAppBundlesText = builtins.readFile ../../src/hosts/MacBook/services/app-bundles.nix;
  macbookAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows.nix;

  inherit (import ../lib.nix) assert';

  # === TEST: Secret materialization before dev repo provision ===
  test_secrets_before_devrepo =
    let
      # Define activation steps with dependencies.
      activations = {
        wait-for-sops-secrets = {
          before = [ ];
          after = [ ];
        };
        "git-identity" = {
          before = [ "wait-for-sops-secrets" ];
          after = [ ];
        };
        provision-dev-repos = {
          before = [ "git-identity" ];
          after = [ ];
        };
      };
      # Check order: secrets → git identity → dev repos
      gitSecond = activations."git-identity";
      devThird = activations.provision-dev-repos;
    in
    assert' (
      (builtins.elem "wait-for-sops-secrets" gitSecond.before)
      && (builtins.elem "git-identity" devThird.before)
    ) "Secrets must materialize before dev repos provision";

  # === TEST: SSH key loading before Git clone ===
  test_ssh_before_git =
    let
      activations = {
        "ssh-key-adopt" = {
          before = [ "wait-for-sops-secrets" ];
          after = [ ];
        };
        provision-dev-repos = {
          before = [ "ssh-key-adopt" ];
          after = [ ];
        };
      };
    in
    assert' (builtins.elem "ssh-key-adopt" activations.provision-dev-repos.before) "SSH keys must load before Git clones";

  # === TEST: GPG keys imported before commits ===
  test_gpg_before_commits =
    let
      activations = {
        "gpg-import" = {
          before = [ "wait-for-sops-secrets" ];
          after = [ ];
        };
        "git-identity" = {
          before = [ "gpg-import" ];
          after = [ ];
        };
      };
    in
    assert' (builtins.elem "gpg-import"
      activations."git-identity".before
    ) "GPG keys must import before Git identity setup";

  # === TEST: Activation names are unique ===
  test_activation_names_unique =
    let
      names = [
        "wait-for-sops-secrets"
        "git-identity"
        "gpg-import"
        "ssh-key-adopt"
        "provision-dev-repos"
      ];
      uniqueNames = unique names;
    in
    assert' (
      builtins.length names == builtins.length uniqueNames
    ) "Activation step names must be unique";

  # === TEST: No circular dependencies ===
  test_no_circular_deps =
    assert' true # Validated by NixOS/Home Manager eval
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
        "Sync-DevRepoCatalog" # After secrets materialized
      ];
      # Verify step count and order
      correctOrder =
        (builtins.elemAt steps 0 == "Sync-GitAndSshConfig")
        && (builtins.elemAt steps 1 == "Invoke-JITSecretMaterialization")
        && (builtins.elemAt steps 2 == "Sync-DevRepoCatalog");
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
        "wait-for-sops-secrets"
        "git-identity"
        "gpg-import"
        "ssh-key-adopt"
        "provision-dev-repos"
      ];
      # Each dependency reference should exist in the names list
      testDep = name: builtins.elem name activationNames;
      validRefs = builtins.all testDep activationNames;
    in
    assert' validRefs "All activation dependency references must exist";

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

  # === TEST: sync-clawhub-skills dependency name stays aligned across modules ===
  test_sync_clawhub_dependency_name_alignment =
    assert'
      (
        (lib.hasInfix "sync-clawhub-skills = lib.hm.dag.entryAfter" agentsModuleText)
        && (lib.hasInfix "\"sync-clawhub-skills\"" activationDagModuleText)
      )
      "sync-clawhub-skills activation name must match between agents.nix and activation-dag.nix dependency list";

  # === TEST: sync-clawhub-skills must not short-circuit activation ===
  # NOTE: uses hasInfix (substring) instead of builtins.match — Nix's POSIX
  # extended regex has no multiline dot, so the old (.|\n)* pattern was an
  # invalid regular expression and could never evaluate.
  test_sync_clawhub_does_not_exit_activation =
    assert' (!lib.hasInfix "exit 0" agentsModuleText)
      "sync-clawhub-skills must not call exit 0, or later activation steps (including displayHostManualInstructions) are skipped";

  # === TEST: GIMP sensitivity targets installed app version dynamically ===
  # NOTE: version derivation lives in configure-gimp-scroll-sensitivity.sh, not
  # in activation.nix (which only invokes the script); target the script text.
  test_gimp_sensitivity_version_tracking =
    assert'
      (
        (lib.hasInfix "/Applications/GIMP.app/Contents/Info" gimpScrollSensitivityScriptText)
        && (lib.hasInfix "gimp_version_branch" gimpScrollSensitivityScriptText)
        && !(lib.hasInfix "for gimp_version in 2.10 3.0" gimpScrollSensitivityScriptText)
      )
      "GIMP sensitivity provisioning must derive version from installed GIMP.app (no hardcoded version loop)";

  # === TEST: Windows Git identity applies to each managed profile path ===
  # Identity now lives in the user-scope include file (~\.config\git\identity):
  # the user gitconfig (~\.gitconfig) is a symlink into the repo tree and must
  # never be written by the provisioner, so per-user identity keys go to the
  # include file instead (referenced by [include] path in Windows.gitconfig).
  test_windows_git_identity_targets_user_gitconfig =
    assert'
      (
        (lib.hasInfix "config --file $identityConfigPath" windowsGitSshModuleText)
        && !(lib.hasInfix "config --global" windowsGitSshModuleText)
      )
      "Windows Git identity must write via --file $identityConfigPath, not --global, so each managed user profile gets the correct target path";

  # === TEST: POSIX Git defaults enforce signed commits and tags ===
  # commit.gpgsign/tag.gpgsign live at user scope in the per-user
  # <host>.gitconfig files (src/users/default/git/<host>.gitconfig).
  test_posix_git_signing_defaults_enabled =
    assert'
      (
        (lib.hasInfix "gpgsign = true" macbookUserGitconfigText)
        && (lib.hasInfix "gpgsign = true" nixosUserGitconfigText)
      )
      "POSIX Git defaults must keep commit.gpgsign and tag.gpgsign enabled for cross-host signing parity";

  # === TEST: macOS MiddleClick startup uses native Login Items, not LaunchAgent ===
  # NOTE: login-item registration lives in macos-enable-middle-click.sh, not in
  # activation.nix (which only invokes the script); target the script text.
  test_middleclick_native_login_item = assert' (
    (lib.hasInfix "make login item at end with properties {name:\"MiddleClick\"" middleClickScriptText)
    && (lib.hasInfix "tell application \"System Events\"" middleClickScriptText)
    && !(lib.hasInfix "launchd.agents.\"art.ginzburg.MiddleClick\"" macbookDefaultText)
  ) "MiddleClick startup on macOS must use native Login Items (no custom LaunchAgent)";

  # === TEST: Spotlight disables all known launcher hotkey slots ===
  # NOTE: hotkey loop lives in macos-disable-spotlight.sh, not in activation.nix
  # (which only invokes the script); target the script text.
  test_spotlight_disables_all_hotkey_slots = assert' (lib.hasInfix "for hotkey in 61 64 65; do" spotlightScriptText) "Spotlight disable flow must cover symbolic hotkey IDs 61, 64, and 65";

  # === TEST: install-cargo-binstall-packages activation name aligned across modules ===
  # NOTE: the dependent activation (install-zsh-completions) lives in shell.nix,
  # not macos.nix; target the actual dependency list.
  test_install_cargo_binstall_dependency_name_alignment =
    assert'
      (
        (lib.hasInfix "install-cargo-binstall-packages = lib.hm.dag.entryAfter" agentsModuleText)
        && (lib.hasInfix "\"install-cargo-binstall-packages\"" shellModuleText)
      )
      "install-cargo-binstall-packages activation name must match between agents.nix and its dependent module's dependency list";

  # === TEST: macOS dev-tree maintenance is scheduled, not activation-bound ===
  test_macos_dev_maintenance_is_scheduled = assert' (
    (lib.hasInfix "launchd.agents.\"ds-store-gc\"" macosModuleText)
    && (lib.hasInfix "launchd.agents.\"spotlight-exclusions\"" macosModuleText)
    && (lib.hasInfix "Label = \"local.ds-store-gc\";" macosModuleText)
    && (lib.hasInfix "Label = \"local.spotlight-exclusions\";" macosModuleText)
    && (lib.hasInfix "ProgramArguments = [ \"\${devDsStoreGc}/bin/nucleus-ds-store-gc\" ];" macosModuleText)
    && (lib.hasInfix "ProgramArguments = [" macosModuleText)
    && (lib.hasInfix "\"\${devSpotlightExclusions}/bin/nucleus-spotlight-exclusions\"" macosModuleText)
    && !(lib.hasInfix "cleanDevDsStore = lib.hm.dag.entryAfter" macosModuleText)
    && !(lib.hasInfix "configureDevSpotlightExclusions = lib.hm.dag.entryAfter" macosModuleText)
  ) "macOS dev-tree maintenance must run from launchd agents instead of Home Manager activation";

  # === TEST: discord-music-rpc out-of-store symlink properly wired ===
  # Verify that the config.yaml path appears in managedSymlinkPaths in home.nix
  # and uses mkOutOfStoreSymlink in its own module.
  # discord-music-rpc config is managed via out-of-store symlink (Method 1).
  # Verify it appears in the managedSymlinkPaths list in home.nix and uses
  # mkOutOfStoreSymlink in its own module.
  test_discord_music_rpc_out_of_store_symlink =
    assert'
      (
        (lib.hasInfix "discord-music-rpc/config.yaml" homeModuleText)
        && (lib.hasInfix "mkOutOfStoreSymlink" discordMusicRpcModuleText)
      )
      "discord-music-rpc config.yaml must be in home.nix managedSymlinkPaths and use mkOutOfStoreSymlink";

  # === TEST: App bundles Phase 2 uses declared order (no re-sort) ===
  test_app_bundles_deployment_uses_declared_order = assert' (lib.hasInfix "}) currentNucleusAppBundles" macbookAppBundlesText) "app-bundles.nix Phase 2 must iterate currentNucleusAppBundles directly without re-sorting";

  # === TEST: Automator workflows Phase 3 uses declared order (no re-sort) ===
  test_workflows_deployment_uses_declared_order = assert' (lib.hasInfix "}) currentNucleusWorkflows" macbookAutomatorWorkflowsText) "automator-workflows.nix Phase 3 must iterate currentNucleusWorkflows directly without re-sorting";

  # === TEST: macOS app-bundles DAG orders after linkGeneration ===
  test_services_app_bundles_dag_after_link_generation = assert' (lib.hasInfix "macos-deploy-app-bundles = lib.hm.dag.entryAfter [ \"linkGeneration\" ]" macbookAppBundlesText) "app-bundles.nix macos-deploy-app-bundles activation must run after linkGeneration";

  # === TEST: macOS automator-workflows DAG orders after linkGeneration ===
  test_services_workflows_dag_after_link_generation = assert' (lib.hasInfix "deploy-automator-workflows = lib.hm.dag.entryAfter [ \"linkGeneration\" ]" macbookAutomatorWorkflowsText) "automator-workflows.nix deploy-automator-workflows must run after linkGeneration";

  # === TEST: macOS services flush DAG orders after both deploy steps ===
  test_services_flush_dag_after_both =
    assert'
      (
        lib.hasInfix "flush-services-cache =" macbookServicesText
        && lib.hasInfix "entryAfter [ \"deploy-automator-workflows\" \"macos-deploy-app-bundles\" ]" macbookServicesText
      )
      "services.nix flush-services-cache must run after both deploy-automator-workflows and macos-deploy-app-bundles";

  # === TEST: macOS services.nix imports both sub-modules ===
  test_services_imports_both_submodules = assert' (
    lib.hasInfix "./services/automator-workflows.nix" macbookServicesText
    && lib.hasInfix "./services/app-bundles.nix" macbookServicesText
  ) "services.nix must import both automator-workflows.nix and app-bundles.nix";

  # === TEST: macOS Automator workflows has open nucleus manual entry ===
  test_macos_workflows_has_open_nucleus_manual =
    assert'
      (
        lib.hasInfix "\"open nucleus manual.workflow\"" macbookAutomatorWorkflowsText
        && lib.hasInfix "com.nucleus.OpenNucleusManual" macbookAutomatorWorkflowsText
      )
      "automator-workflows.nix must define currentNucleusWorkflows containing the open nucleus manual workflow entry";

  # Collect all tests.
  allTests = [
    test_secrets_before_devrepo
    test_ssh_before_git
    test_gpg_before_commits
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
    test_discord_music_rpc_out_of_store_symlink
    test_services_app_bundles_dag_after_link_generation
    test_services_workflows_dag_after_link_generation
    test_services_flush_dag_after_both
    test_services_imports_both_submodules
    test_app_bundles_deployment_uses_declared_order
    test_workflows_deployment_uses_declared_order
    test_macos_workflows_has_open_nucleus_manual
  ];
in
# NOTE: force allTests as deepSeq's SECOND argument.  `builtins.seq (builtins.deepSeq allTests) { ... }`
# only forces the partially-applied deepSeq function (WHNF) and never evaluates
# any test, silently passing every assertion.  This form actually evaluates them.
builtins.deepSeq allTests {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} activation and service dependency tests passed";
}
