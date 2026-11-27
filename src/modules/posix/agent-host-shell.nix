# Wrapper for VS Code agent-host terminals (sets agent env vars).
#
# Renamed to nucleus-agent-host-shell for command-surface clarity. It remains a
# wrapper file (documented exception, not a nucleus app) because the consumer
# takes a path and cannot pass command arguments.
#
# It lives at the SYSTEM root bin, so a root-context system activation script
# writes it. nix-darwin only honors hardcoded fragment names, hence
# postActivation there; NixOS takes a custom lowerCamelCase name.
{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    mkAfter
    mkIf
    ;

  realShellExe = lib.getExe pkgs.zsh;

  # Stable path the agentHostProfile VS Code setting points at.
  wrapperPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/bin/nucleus-agent-host-shell"
    else
      "/var/lib/nucleus/bin/nucleus-agent-host-shell";

  activationBundle = pkgs.callPackage ../lib/script-tree.nix { };
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the VS Code agent-host wrapper script (nucleus-agent-host-shell) at the SYSTEM root bin (macOS /Library/Application Support/nucleus/bin, NixOS /var/lib/nucleus/bin). Documented exception: a path-only consumer, not a nucleus app.";
    };
  };

  # Each platform branch is a deferred thunk: a bare `if` evaluates its `pkgs`
  # reference while `config` is being constructed, which forces `pkgs`
  # resolution through `_module.args` and recurses.
  config = lib.mkMerge [
    (mkIf pkgs.stdenv.hostPlatform.isDarwin {
      # Fragment from src/modules/posix/agent-host-shell.nix
      system.activationScripts.postActivation.text = mkAfter ''
        "${activationBundle}/src/scripts/agent-host-shell/write-wrapper.sh" \
          "${wrapperPath}" \
          "${realShellExe}"
      '';
    })
    (mkIf (!pkgs.stdenv.hostPlatform.isDarwin) {
      # Fragment from src/modules/posix/agent-host-shell.nix
      system.activationScripts.agentHostShell.text = mkAfter ''
        "${activationBundle}/src/scripts/agent-host-shell/write-wrapper.sh" \
          "${wrapperPath}" \
          "${realShellExe}"
      '';
    })
  ];
}
