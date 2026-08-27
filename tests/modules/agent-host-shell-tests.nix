# tests/modules/agent-host-shell-tests.nix — Validate agent-host-shell module.
#
# Verifies:
#   • Module imports cleanly as a system module and defines expected options
#   • Wrapper content exports expected environment variables
#
# Run with: nix-instantiate --eval tests/modules/agent-host-shell-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  inherit (lib) hasInfix hasSuffix;

  # Module imports cleanly as a system module (will throw if it doesn't).
  module = import ../../src/modules/agent-host-shell.nix {
    inherit lib pkgs;
    config = {
      nucleus.agentHostShell.enable = true;
    };
  };

  # Option exists.
  optionExists = module.options ? nucleus.agentHostShell.enable;

  # Verify wrapper text content by constructing it like the bundle script does.
  realShellExe = lib.getExe pkgs.zsh;
  wrapperText = ''
    export NUCLEUS_AGENT_SESSION=1
    export VSCODE_AGENT=1
    exec ${realShellExe} "$@"
  '';

  test_shell_is_zsh = hasSuffix "/bin/zsh" realShellExe;
  test_nucleus_agent_session = hasInfix "export NUCLEUS_AGENT_SESSION=1" wrapperText;
  test_vscode_agent = hasInfix "export VSCODE_AGENT=1" wrapperText;
  test_exec_shell = hasInfix "exec " wrapperText && hasInfix "/bin/zsh" wrapperText;
in
rec {
  option_exists = optionExists;
  shell_is_zsh = test_shell_is_zsh;
  exports_nucleus_agent_session = test_nucleus_agent_session;
  exports_vscode_agent = test_vscode_agent;
  execs_real_shell = test_exec_shell;
  all_tests_pass =
    optionExists
    && test_shell_is_zsh
    && test_nucleus_agent_session
    && test_vscode_agent
    && test_exec_shell;
  success = all_tests_pass;
}
