# Terminal-context activation scripts.
#
# Defines `nucleus.terminalActivations` — activation commands that must run in
# the user's terminal context (outside the Nix rebuild) so macOS TCC grants
# (Full Disk Access, Accessibility) are inherited.  A Home Manager activation
# entry serialises the commands to a plain-text manifest consumed by
# apply.sh / apply.ps1 after the rebuild completes.
#
# ── Policy ─────────────────────────────────────────────────────────────────
#
# Terminal activations are a LAST RESORT.  Never add a new entry unless:
#
#   1. The command MUST run in the user's terminal context (outside sudo/Nix
#      activation) — typically because macOS TCC grants (Full Disk Access,
#      Accessibility) are required and would be lost inside the sudo process
#      tree during darwin-rebuild switch.
#   2. No alternative exists: the command cannot be refactored into a Nix
#      declarative option, a Home Manager activation entry, or a system
#      activation script that runs inside the rebuild.
#   3. The technical constraint is documented inline with a `# WHY:` comment
#      at the call site (see: src/modules/macos.nix for the established
#      pattern).
#
# If a command does not need TCC-sensitive context (FDA, Accessibility,
# Screen Recording, Automation), it SHOULD run as a normal Nix/Home Manager
# activation entry.  Terminal activations are inherently imperative (eval'd
# from a text file) and bypass the declarative Nix model — each use erodes
# reproducibility.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, ... }:

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
    home.activation.write-terminal-activations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
