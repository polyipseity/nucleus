# tests/modules/agent-host-shell-tests.nix — VS Code agent-host wrapper wiring.
#
# src/modules/posix/agent-host-shell.nix lost its importer in f90f0943, so no
# activation has owned the wrapper since. Nothing failed loudly: a fresh NixOS
# host simply got no wrapper at all, and macOS kept serving an ~3-week-old copy
# that VS Code still points at. These tests bind the module's REAL evaluated
# activation fragment to the path VS Code is configured to launch, so the two
# cannot drift apart again.
#
# The previous version of this file was deleted in 5ded7fda because it hand-wrote
# a wrapper string and then asserted that its own string contained it — a
# tautology that exercised nothing in the module. Every value below is read from
# the evaluated module or from the committed settings file, never restated from
# the module being checked.
#
# Run with: nix-instantiate --eval --strict tests/modules/agent-host-shell-tests.nix

let
  inherit (import ../lib.nix) assert';

  lib = import <nixpkgs/lib>;

  inherit (lib) hasInfix;

  # Both package sets are pinned to an explicit system. An unpinned
  # `import <nixpkgs> { }` resolves to the HOST, so the darwin evaluation below
  # would silently become x86_64-linux on the ubuntu-latest leg of the CI matrix
  # and take the NixOS branch in agent-host-shell.nix — leaving the darwin branch
  # of the module verified on one host only, with nothing reporting the gap. Same
  # trap as tests/modules/posix-module-imports-tests.nix, where it was the one P0
  # this effort caught late. Evaluation only, nothing is built, so either host
  # can evaluate either set.
  darwinPkgs = import <nixpkgs> { system = "aarch64-darwin"; };
  linuxPkgs = import <nixpkgs> { system = "x86_64-linux"; };

  # The module under test, evaluated for real. This forces the option
  # declaration and produces the activation fragment the host would run, which
  # is the artifact the wrapper actually comes from. The stub supplies the
  # platform option surface: `system.activationScripts` belongs to nix-darwin and
  # NixOS, not to the generic module system, so without it the module has nothing
  # to attach its fragment to.
  #
  # Parameterised by package set so both platform branches are evaluated on every
  # host. The module picks its wrapper root at :25-28 and guards its two
  # activation fragments with mkIf on hostPlatform at :48 and :56, so a
  # single-platform evaluation leaves one of them permanently unexercised.
  evaluatedFor =
    pkgs:
    lib.evalModules {
      modules = [
        (import ../../src/modules/posix/agent-host-shell.nix { inherit lib pkgs; })
        {
          options.system.activationScripts = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.lines);
            default = { };
          };
        }
      ];
    };

  activationFor =
    evaluated:
    builtins.concatStringsSep "\n" (
      lib.mapAttrsToList (_name: fragment: fragment.text or "") evaluated.config.system.activationScripts
    );

  darwinEval = evaluatedFor darwinPkgs;
  linuxEval = evaluatedFor linuxPkgs;
  darwinActivation = activationFor darwinEval;
  linuxActivation = activationFor linuxEval;

  # Settings keys are flat and dotted, not nested.
  vscode = builtins.fromJSON (builtins.readFile ../../src/users/default/vscode/settings.json);
  agentProfiles = {
    osx = vscode."terminal.integrated.agentHostProfile.osx";
    linux = vscode."terminal.integrated.agentHostProfile.linux";
    windows = vscode."terminal.integrated.agentHostProfile.windows";
  };

  # The documented SYSTEM roots. Duplicated deliberately: comparing the module
  # against an independent restatement is the entire point, so this copy must
  # not be derived from the module.
  # ref: nucleus-apps.instructions.md#agent-host-shell -- documented wrapper location per host
  documentedSystemRoots = {
    osx = "/Library/Application Support/nucleus";
    linux = "/var/lib/nucleus";
  };

  wrapperPathFor = platform: "${documentedSystemRoots.${platform}}/bin/agent-host-shell";

  test_option_is_declared = assert' (
    darwinEval.options ? nucleus.agentHostShell.enable
  ) "the module must declare options.nucleus.agentHostShell.enable";

  test_option_defaults_to_enabled = assert' (
    darwinEval.options.nucleus.agentHostShell.enable.default == true
  ) "agentHostShell.enable must default to true, or no host ever gets a wrapper";

  # Behavioral: each path is read out of the activation that platform would
  # really run, so a module that stops emitting it fails here rather than at
  # apply time. Both branches are asserted on every host, so neither depends on
  # the runner it happens to run on.
  test_darwin_wrapper_path_is_in_the_activation = assert' (hasInfix (wrapperPathFor "osx") darwinActivation) "the darwin activation must reference the documented wrapper path ${wrapperPathFor "osx"}";

  test_linux_wrapper_path_is_in_the_activation = assert' (hasInfix (wrapperPathFor "linux") linuxActivation) "the linux activation must reference the documented wrapper path ${wrapperPathFor "linux"}";

  test_activation_invokes_the_writer = assert' (
    hasInfix "write-wrapper.sh" darwinActivation && hasInfix "write-wrapper.sh" linuxActivation
  ) "both activations must invoke write-wrapper.sh";

  # A renamed or deleted script would otherwise only surface as a failed apply.
  test_writer_script_exists = assert' (builtins.pathExists ../../src/scripts/agent-host-shell/write-wrapper.sh) "src/scripts/agent-host-shell/write-wrapper.sh must exist for the activation to succeed";

  test_darwin_wrapper_matches_vscode_profile =
    assert' (agentProfiles.osx.path == wrapperPathFor "osx")
      "VS Code's osx agentHostProfile (${agentProfiles.osx.path}) must be the path the darwin module installs (${wrapperPathFor "osx"})";

  test_linux_wrapper_matches_vscode_profile =
    assert' (agentProfiles.linux.path == wrapperPathFor "linux")
      "VS Code's linux agentHostProfile (${agentProfiles.linux.path}) must be the path the linux module installs (${wrapperPathFor "linux"})";

  test_both_posix_profiles_match_system_roots = assert' (
    agentProfiles.osx.path == "${documentedSystemRoots.osx}/bin/agent-host-shell"
    && agentProfiles.linux.path == "${documentedSystemRoots.linux}/bin/agent-host-shell"
  ) "both POSIX agentHostProfile paths must be the documented SYSTEM root bin";

  # The Windows twin is served by the PowerShell module, out of scope here; this
  # only asserts the parity entry exists rather than that its content is right.
  test_windows_profile_is_present = assert' (
    agentProfiles.windows.path != ""
  ) "the Windows agentHostProfile entry must still exist for cross-host parity";

  allTests = [
    test_option_is_declared
    test_option_defaults_to_enabled
    test_darwin_wrapper_path_is_in_the_activation
    test_linux_wrapper_path_is_in_the_activation
    test_activation_invokes_the_writer
    test_writer_script_exists
    test_darwin_wrapper_matches_vscode_profile
    test_linux_wrapper_matches_vscode_profile
    test_both_posix_profiles_match_system_roots
    test_windows_profile_is_present
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} agent-host-shell tests passed";
}
