# modules/agent-host-shell.nix — VS Code agent-host wrapper script.
#
# VS Code's AgentHostTerminalManager spawns shell sessions via node-pty
# directly, bypassing workbench terminal profiles and settings. This means
# agent detection environment variables (NUCLEUS_AGENT_SESSION, VSCODE_AGENT)
# are never set in agent-host terminals.
#
# This module creates a thin wrapper script that exports those variables and
# then execs the real shell, then writes the wrapper path into
# agent-host-config.json so AgentHostTerminalManager uses it as the default
# shell on POSIX hosts.
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
  # programs.zsh.enable is always set (shell.nix), so pkgs.zsh is the
  # canonical shell. Use it directly rather than config.home.shell, which
  # may resolve to a non-coercible set in certain Home Manager versions.
  realShellExe = lib.getExe pkgs.zsh;

  # Thin wrapper: export agent detection vars, then exec real shell.
  wrapperPkg = pkgs.writeShellScript "agent-host-wrapper.sh" ''
    export NUCLEUS_AGENT_SESSION=1
    export VSCODE_AGENT=1
    exec ${realShellExe} "$@"
  '';

  wrapperPath = "${wrapperPkg}/bin/agent-host-wrapper.sh";
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to set up the VS Code agent-host wrapper script and write agent-host-config.json.";
    };
  };

  config = mkIf cfg.enable {
    home.activation.agentHostShellConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      set -eu

      _wrapper_path='${wrapperPath}'

      # Write agent-host-config.json for stable and Insiders channels.
      _json_content='{"defaultShell":"'"$_wrapper_path"'"}'

      case "$(uname -s)" in
        Darwin)
          _base="$HOME/Library/Application Support"
          ;;
        Linux)
          _base="$HOME/.config"
          ;;
        *)
          echo "agent-host-shell: unsupported OS $(uname -s)" >&2
          exit 1
          ;;
      esac

      for _channel in "Code" "Code - Insiders"; do
        _global_storage="$_base/$_channel/User/globalStorage"
        mkdir -p "$_global_storage"
        echo "$_json_content" > "$_global_storage/agent-host-config.json"
        echo "agent-host-shell: wrote $_global_storage/agent-host-config.json"
      done
    '';
  };
}
