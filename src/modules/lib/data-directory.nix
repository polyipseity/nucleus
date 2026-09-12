# src/modules/lib/data-directory.nix — Centralized ~/data provisioning manifest.
#
# Defines system-level operations for the provision-data-directory.sh script.
# Each module that needs to create directories, files, or symlinks under ~/data
# adds its entries here. The manifest is consumed by the activation entry in
# home.nix.
#
# Invariant: the script only creates. It never deletes files, folders, or
# symlinks. If a target already exists, it is left untouched.
{
  lib,
  config,
  ...
}:
let
  homeDir = config.home.homeDirectory;

  # Base operations applied on every host. Apps add their entries via
  # lib.mkMerge in the config section.
  baseOps = [ ];

  # Hermes-agent SOUL.md provisioning. The persona file lives outside the
  # repo in ~/data/hermes-agent/ and is symlinked from ~/.hermes/SOUL.md.
  hermesOps = [
    {
      op = "dir";
      path = "hermes-agent";
    }
    {
      op = "file";
      path = "hermes-agent/SOUL.md";
      content = ''
        You are Hermes Agent, built by Nous Research. Be direct: match the length of your reply to the weight of the ask — a one-line question gets a one-line answer, and finished work gets a short report of what changed, what's verified, and what's left, never a replay of the process. No filler ("Great question," "I'd be happy to"), no restating the request back, no re-summarizing what you already said, no narrating tool calls the user can see. Plain claims over adjectives; when unsure, say so plainly. Agree because it's right, not because the user said it. Depth is earned — give it when the user asks for detail, teaches, or the stakes demand it, not by default.
      '';
    }
    {
      op = "symlink";
      path = "${homeDir}/.hermes/SOUL.md";
      target = "${homeDir}/data/hermes-agent/SOUL.md";
    }
  ];
in
{
  # The manifest is a list of operation attrsets. Each module appends its ops
  # via lib.mkMerge. The final merged list is passed to the shell script.
  options.nucleus.dataDirectory.manifest = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
    description = "List of data-directory provisioning operations consumed by provision-data-directory.sh.";
  };

  config = {
    nucleus.dataDirectory.manifest = lib.mkMerge [
      baseOps
      hermesOps
    ];
  };
}
