# tests/integration/activation-deps-tests.nix — Validate activation dependency ordering.
#
# Tests verify that Home Manager activation hooks are ordered correctly so
# dependencies are satisfied before dependents run.
# Key invariants:
# - Secret materialization before dev repo provisioning
# - SSH keys loaded before git clones over SSH
# - GPG keys imported before signed commits
# - LaunchAgent refresh before cloud drive mount-path convergence
# - Cloud drive LaunchAgent label wired module → convergence script
# - Cloud drive mount points under the user's home, never under /Volumes
# - App-bundle NSServicesStatus entries merged after the workflow whole-dict write
#
let
  lib = import <nixpkgs/lib>;
  inherit (lib) unique;

  inherit (import ../lib.nix) assert';

  hermesAgentModuleText = builtins.readFile ../../src/modules/hermes-agent.nix;
  # nixfmt reflows the module, so call-form assertions must be insensitive to line
  # breaks and indentation.
  hermesAgentModuleTextFlat = lib.concatStringsSep " " (
    builtins.filter (part: builtins.isString part && part != "") (
      builtins.split "[ \t\n]+" hermesAgentModuleText
    )
  );

  cloudDrivesModuleText = builtins.readFile ../../src/modules/cloud-drives.nix;
  cloudDrivesModuleTextFlat = lib.concatStringsSep " " (
    builtins.filter (part: builtins.isString part && part != "") (
      builtins.split "[ \t\n]+" cloudDrivesModuleText
    )
  );

  appBundlesModuleText = builtins.readFile ../../src/hosts/MacBook/services/app-bundles/default.nix;
  appBundlesModuleTextFlat = lib.concatStringsSep " " (
    builtins.filter (part: builtins.isString part && part != "") (
      builtins.split "[ \t\n]+" appBundlesModuleText
    )
  );

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

  # === TEST: hermes env files wait for sops-nix materialization ===
  # WHY: grep-only — tests a critical invariant about hermes secrets ordering.
  # On macOS sops-nix materializes secrets from an asynchronous LaunchAgent, so
  # ordering the consumer merely after "sops-nix" does not gate on the file
  # existing; the barrier must sit between sops-nix and hermesAgentSetup.
  # entryBetween takes the BEFORE list first — swapped lists put the barrier after
  # the step that reads the secrets, which is how the original bug shipped.
  test_hermes_secrets_barrier_between_sops_and_setup =
    assert'
      (
        lib.hasInfix "wait-for-sops-secrets.sh" hermesAgentModuleText
        && lib.hasInfix "hermesSecrets != [ ]" hermesAgentModuleText
        && lib.hasInfix ''entryBetween [ "hermesAgentSetup" ] [ "setupLaunchAgents" "sops-nix" ]'' hermesAgentModuleTextFlat
      )
      "hermes environment files must wait for sops-nix to materialize, before hermesAgentSetup and after setupLaunchAgents + sops-nix";

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

  # === TEST: cloud drive mount paths converge after the LaunchAgents refresh ===
  # WHY: grep-only — the ordering is a module-evaluation fact that is not
  # exposed without a full Home Manager evaluation.  macos-configure-icloud-exclusions
  # already sits after cloud-drives-setup, so the two orderings compose into the
  # activation DAG.  On macOS the mount agents are refreshed by setupLaunchAgents
  # (plist compare, then bootout/bootstrap), and that refresh is what releases a
  # volume still attached at the previous layout's clouds/<id> path.  Converging
  # first therefore hits a live mount the convergence step must refuse, and the
  # apply can never reach the refresh that would clear it.  The writeBoundary
  # anchor stays because HM requires side-effecting entries to run after it.
  test_cloud_drives_converge_after_launch_agents =
    assert'
      (
        lib.hasInfix ''home.activation.cloud-drives-setup = lib.hm.dag.entryAfter [ "writeBoundary" "setupLaunchAgents" ]'' cloudDrivesModuleTextFlat
        && !(lib.hasInfix ''home.activation.cloud-drives-setup = lib.hm.dag.entryAfter [ "writeBoundary" ]'' cloudDrivesModuleTextFlat)
      )
      "cloud drive mount paths must converge after the LaunchAgent refresh, and still after writeBoundary";

  # === TEST: cloud drive mounts carry one LaunchAgent label ===
  # WHY: grep-only — the label is the text contract between the module and the
  # convergence script, which can only name the agent that holds the mount if the
  # Nix side actually passes it.  Dropping the `serviceLabel` line would silently
  # downgrade the diagnostic to "fix manually and re-apply" while every suite
  # stayed green, so pin all three facts: the single binding, the agent that uses
  # it, and the JSON field the script reads.
  test_cloud_drives_label_wiring =
    assert'
      (
        lib.hasInfix ''mountLabel = mount: "local.cloud-mount.''${mount.id}";'' cloudDrivesModuleTextFlat
        && lib.hasInfix "serviceLabel = mountLabel m;" cloudDrivesModuleTextFlat
        && lib.hasInfix "Label = mountLabel mount;" cloudDrivesModuleTextFlat
      )
      "cloud drive mounts must derive the LaunchAgent label from one binding and pass it to the convergence script";

  # === TEST: cloud drive mount points live under the user's home ===
  # WHY: grep-only — /Volumes is a trap here.  rclone stats the mount point
  # before mounting and aborts when it is missing, while macFUSE creates a
  # /Volumes mount point only as part of the mount itself, so a mount point
  # under /Volumes can never come into existence.  Pinning the inline expression
  # (and the absence of a host-conditional helper) keeps the wrapper's mount
  # point and the convergence script's real directory in agreement.
  test_cloud_drives_mount_point_under_home = assert' (
    lib.hasInfix ''mountPoint = "''${currentUserHome}/''${mount.localPath}";'' cloudDrivesModuleTextFlat
    && !(lib.hasInfix "mkMountPoint" cloudDrivesModuleText)
    && !(lib.hasInfix "/Volumes/nucleus-cloud-" cloudDrivesModuleText)
  ) "cloud drive mounts must live under the user's home directory, never under /Volumes";

  # === TEST: app-bundle services merge after the workflow whole-dict write ===
  # WHY: grep-only — the ordering is a module-evaluation fact that is not
  # exposed without a full Home Manager evaluation.  macos-deploy-automator-workflows
  # rewrites the entire NSServicesStatus dictionary, because `defaults -dict-add`
  # rejects its parenthesised workflow keys at parse time (parens are old-style
  # plist array syntax) so it cannot merge; that rewrite erases app-bundle
  # entries.  macos-deploy-app-bundles re-adds its own entries with the
  # merge-capable `-dict-add`, so it has to run last.  Both entries otherwise
  # default to linkGeneration, where the attribute-name tie-break runs the
  # app-bundle step first and the workflow step erases its entries every apply.
  test_app_bundles_after_automator_workflows = assert' (
    lib.hasInfix ''home.activation.macos-deploy-app-bundles = lib.hm.dag.entryAfter [ "linkGeneration" "macos-deploy-automator-workflows" ]'' appBundlesModuleTextFlat
    && !(lib.hasInfix ''home.activation.macos-deploy-app-bundles = lib.hm.dag.entryAfter [ "linkGeneration" ]'' appBundlesModuleTextFlat)
  ) "app-bundle NSServicesStatus entries must merge after the workflow whole-dict write";

  # Collect all tests.
  allTests = [
    test_secrets_before_devrepo
    test_ssh_before_git
    test_gpg_before_commits
    test_activation_names_unique
    test_hermes_secrets_barrier_between_sops_and_setup
    test_cloud_drives_converge_after_launch_agents
    test_cloud_drives_label_wiring
    test_cloud_drives_mount_point_under_home
    test_app_bundles_after_automator_workflows
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
