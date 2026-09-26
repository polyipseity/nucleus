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
  pkgs = import <nixpkgs> { };

  inherit (lib) hasInfix;

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # The module under test, evaluated for real. This forces the option
  # declaration and produces the activation fragment this host would run, which
  # is the artifact the wrapper actually comes from. The stub supplies the
  # platform option surface: `system.activationScripts` belongs to nix-darwin and
  # NixOS, not to the generic module system, so without it the module has nothing
  # to attach its fragment to.
  evaluated = lib.evalModules {
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

  activationText = builtins.concatStringsSep "\n" (
    lib.mapAttrsToList (_name: fragment: fragment.text or "") evaluated.config.system.activationScripts
  );

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

  expectedWrapperPath = "${
    documentedSystemRoots.${if isDarwin then "osx" else "linux"}
  }/bin/agent-host-shell";
  vscodeProfile = if isDarwin then agentProfiles.osx else agentProfiles.linux;

  test_option_is_declared = assert' (
    evaluated.options ? nucleus.agentHostShell.enable
  ) "the module must declare options.nucleus.agentHostShell.enable";

  test_option_defaults_to_enabled = assert' (
    evaluated.options.nucleus.agentHostShell.enable.default == true
  ) "agentHostShell.enable must default to true, or no host ever gets a wrapper";

  # Behavioral: the path is read out of the activation the host would really run,
  # so a module that stops emitting it fails here rather than at apply time.
  test_wrapper_path_is_in_the_activation = assert' (hasInfix expectedWrapperPath activationText) "the evaluated activation must reference the documented wrapper path ${expectedWrapperPath}";

  test_activation_invokes_the_writer = assert' (hasInfix "write-wrapper.sh" activationText) "the evaluated activation must invoke write-wrapper.sh";

  # A renamed or deleted script would otherwise only surface as a failed apply.
  test_writer_script_exists = assert' (builtins.pathExists ../../src/scripts/agent-host-shell/write-wrapper.sh) "src/scripts/agent-host-shell/write-wrapper.sh must exist for the activation to succeed";

  test_wrapper_matches_vscode_profile =
    assert' (vscodeProfile.path == expectedWrapperPath)
      "VS Code's ${
        if isDarwin then "osx" else "linux"
      } agentHostProfile (${vscodeProfile.path}) must be the path the module installs (${expectedWrapperPath})";

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
    test_wrapper_path_is_in_the_activation
    test_activation_invokes_the_writer
    test_writer_script_exists
    test_wrapper_matches_vscode_profile
    test_both_posix_profiles_match_system_roots
    test_windows_profile_is_present
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} agent-host-shell tests passed";
}
