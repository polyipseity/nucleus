# modules/agent-host-shell.nix — VS Code agent-host wrapper script.
#
# VS Code's AgentHostTerminalManager spawns shell sessions via node-pty
# directly, bypassing workbench terminal profiles and settings. This means
# agent detection environment variables (NUCLEUS_AGENT_SESSION, VSCODE_AGENT)
# are never set in agent-host terminals.
#
# This module creates a thin wrapper script at a stable path
# (.local/bin/nucleus-agent-host-wrapper.sh) via home.file. The wrapper
# exports those variables then execs the real shell. The
# terminal.integrated.agentHostProfile.<os> VS Code setting references this
# path via ${userHome} so that AgentHostTerminalManager uses it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) types mkOption mkIf;
  cfg = config.nucleus.agentHostShell;

  # Resolve the shell binary that the wrapper will exec.
  realShellExe = lib.getExe pkgs.zsh;

  # Stable path referenced by agentHostProfile VS Code setting.
  wrapperFileName = ".local/bin/nucleus-agent-host-wrapper.sh";
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the VS Code agent-host wrapper script at .local/bin/nucleus-agent-host-wrapper.sh.";
    };
  };

  config = mkIf cfg.enable {
    home.file.${wrapperFileName} = {
      executable = true;
      text = ''
        export NUCLEUS_AGENT_SESSION=1
        export VSCODE_AGENT=1
        exec ${realShellExe} "$@"
      '';
    };
  };
}
