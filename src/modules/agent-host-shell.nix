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
  wrapperFileName =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/bin/agent-host-shell"
    else
      "/var/lib/nucleus/bin/agent-host-shell";
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the VS Code agent-host wrapper script at the SYSTEM root bin (macOS /Library/Application Support/nucleus/bin, NixOS /var/lib/nucleus/bin).";
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
