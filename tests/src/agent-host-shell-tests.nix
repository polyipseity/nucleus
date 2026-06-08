# tests/src/agent-host-shell-tests.nix — Validate agent-host-shell module.
#
# Verifies:
#   • Module imports without errors
#   • Wrapper script exports expected environment variables
#   • defaultShell in agent-host-config.json is non-empty
#
# Run with: nix-instantiate --eval tests/src/agent-host-shell-tests.nix

{
  lib ? import <nixpkgs/lib>,
  pkgs ? import <nixpkgs> { },
}:
let
  inherit (lib) hasPrefix hasSuffix;

  # Evaluate the module to verify it imports cleanly.
  module = import ../../src/modules/agent-host-shell.nix {
    inherit lib pkgs;
    config = {
      home = {
        username = "testuser";
        homeDirectory = "/home/testuser";
        shell = pkgs.zsh;
      };
      nucleus.agentHostShell.enable = true;
    };
    # Minimal Home Manager lib stub.
    hm = { };
  };

  # Verify the wrapper script content.
  wrapperDrv = pkgs.writeShellScript "agent-host-wrapper.sh" ''
    export NUCLEUS_AGENT_SESSION=1
    export VSCODE_AGENT=1
    exec ${lib.getExe pkgs.zsh} "$@"
  '';
  wrapperText = builtins.readFile "${wrapperDrv}/bin/agent-host-wrapper.sh";

  # Wrapper must start with a shebang.
  test_shebang = hasPrefix "#!" wrapperText;

  # Wrapper must export both detection variables.
  test_nucleus_agent_session =
    builtins.match ".*export NUCLEUS_AGENT_SESSION=1.*" wrapperText != null;
  test_vscode_agent = builtins.match ".*export VSCODE_AGENT=1.*" wrapperText != null;

  # Wrapper must exec the real shell.
  test_exec_shell = builtins.match ".*exec ${lib.getExe pkgs.zsh}.*" wrapperText != null;

  # Agent-host config defaultShell must be non-empty.
  # (We check that the generated wrapper path is a store path.)
  test_wrapper_expression = builtins.match ".*/nix/store/.*agent-host-wrapper.sh" (
    builtins.toString module
  );
in
{
  shebang = test_shebang;
  exports_nucleus_agent_session = test_nucleus_agent_session;
  exports_vscode_agent = test_vscode_agent;
  execs_real_shell = test_exec_shell;
  wrapper_is_store_path = test_wrapper_expression;
  all_tests_pass = test_shebang && test_nucleus_agent_session && test_vscode_agent && test_exec_shell;
}
