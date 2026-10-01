# Activation commands that must run in the user's terminal context so macOS TCC
# grants survive. A Home Manager entry serialises them to a manifest that
# apply.sh / apply.ps1 consume after the rebuild.
#
# Terminal activations are a last resort; the three conditions an entry has to
# meet are in the instruction file.
# ref: activation-scripts.instructions.md -- Terminal activations
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nucleus.terminalActivations;

  nucleusUserRoot =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "$HOME/Library/Application Support/nucleus"
    else
      "$HOME/.local/share/nucleus";

  sortedEntries = builtins.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (name: entry: { inherit name; } // entry) cfg
  );
in
{
  options.nucleus.terminalActivations = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
            description = "Full command string (script path + arguments) to execute in user terminal context.";
          };
          order = lib.mkOption {
            type = lib.types.int;
            default = 50;
            description = "Execution order (lower runs first).";
          };
        };
      }
    );
    default = { };
    description = ''
      Activation commands that must run in the user's terminal context (outside
      the Nix rebuild), serialised to
      ~/Library/Application Support/nucleus/terminal-activations.list (macOS) /
      ~/.local/share/nucleus/terminal-activations.list (NixOS) for consumption by
      apply.sh / apply.ps1.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    home.activation.write-terminal-activations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="${nucleusUserRoot}/terminal-activations.list"
      mkdir -p "$(dirname "$manifest")"
      : > "$manifest"
      ${lib.concatStringsSep "\n" (
        map (entry: ''
          printf '%s\n' '# ${lib.escapeShellArg entry.name}' >> "$manifest"
          printf '%s\n' '${lib.escapeShellArg entry.command}' >> "$manifest"
        '') sortedEntries
      )}
    '';
  };
}
