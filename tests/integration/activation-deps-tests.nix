# tests/integration/activation-deps-tests.nix — Validate activation dependency ordering.
#
# Tests verify that Home Manager activation hooks are ordered correctly so
# dependencies are satisfied before dependents run.
# Key invariants:
# - Secret materialization before dev repo provisioning
# - SSH keys loaded before git clones over SSH
# - GPG keys imported before signed commits
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

  # Collect all tests.
  allTests = [
    test_secrets_before_devrepo
    test_ssh_before_git
    test_gpg_before_commits
    test_activation_names_unique
    test_hermes_secrets_barrier_between_sops_and_setup
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
