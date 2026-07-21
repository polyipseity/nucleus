# Terminal-context activation scripts.
#
# Defines `nucleus.terminalActivations` — activation commands that must run in
# the user's terminal context (outside the Nix rebuild) so macOS TCC grants
# (Full Disk Access, Accessibility) are inherited.  A Home Manager activation
# entry serialises the commands to a plain-text manifest consumed by
# apply.sh / apply.ps1 after the rebuild completes.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nucleus.terminalActivations;

  # Convert attrset to sorted list preserving names, ordered by `order`.
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
      ~/.config/nucleus/terminal-activations.list for consumption by
      apply.sh / apply.ps1.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    home.activation.writeDarwinTerminalActivations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="$HOME/.config/nucleus/terminal-activations.list"
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
