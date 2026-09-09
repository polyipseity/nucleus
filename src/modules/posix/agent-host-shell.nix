# Wrapper for VS Code agent-host terminals (sets agent env vars).
#
# The wrapper lives at the SYSTEM root bin (root-owned), so it must be written
# by a system activation script (root context), not a Home Manager activation.
# nix-darwin only honors the hardcoded activation fragment names, so macOS uses
# postActivation; NixOS supports a custom kebab-case name.
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

  # Resolve the shell binary that the wrapper will exec.
  realShellExe = lib.getExe pkgs.zsh;

  # Stable path referenced by agentHostProfile VS Code setting.
  wrapperPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/bin/agent-host-shell"
    else
      "/var/lib/nucleus/bin/agent-host-shell";

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  options.nucleus.agentHostShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the VS Code agent-host wrapper script at the SYSTEM root bin (macOS /Library/Application Support/nucleus/bin, NixOS /var/lib/nucleus/bin).";
    };
  };

  # The wrapper is always written by a system activation script (root context).
  # Each platform branch is wrapped in `mkIf` (a deferred thunk) rather than a
  # bare `if/then/else`: a bare conditional evaluates its `pkgs` reference while
  # the `config` attribute is being constructed, which forces `pkgs` resolution
  # through `_module.args` (needing `config`) and recurses. `mkIf` defers the
  # reference until after `config` is available, matching repo-root-file.nix.
  config = lib.mkMerge [
    (mkIf pkgs.stdenv.hostPlatform.isDarwin {
      # Fragment from src/modules/agent-host-shell.nix
      system.activationScripts.postActivation.text = mkAfter ''
        "${activationBundle}/src/scripts/agent-host-shell/write-wrapper.sh" \
          "${wrapperPath}" \
          "${realShellExe}"
      '';
    })
    (mkIf (!pkgs.stdenv.hostPlatform.isDarwin) {
      # Fragment from src/modules/agent-host-shell.nix
      system.activationScripts.agent-host-shell.text = mkAfter ''
        "${activationBundle}/src/scripts/agent-host-shell/write-wrapper.sh" \
          "${wrapperPath}" \
          "${realShellExe}"
      '';
    })
  ];
}
