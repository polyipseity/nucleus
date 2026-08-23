# Wrapper for VS Code agent-host terminals (sets agent env vars).
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
  wrapperFileName = "/etc/nucleus/bin/agent-host-shell";
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the VS Code agent-host wrapper script at /etc/nucleus/bin/agent-host-shell.";
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
