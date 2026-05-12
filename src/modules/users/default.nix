# modules/users/default.nix — Centralized user registry for multi-user support.
#
# Defines the set of users managed by this configuration. Each user has a
# home directory, shell, and role (primary vs secondary). The primary user
# receives secret materialization; secondary users get base configuration only.
#
# This registry replaces hardcoded username strings in flake.nix, enabling
# the same configuration to serve multiple users across macOS, NixOS, and
# Windows hosts.
{ lib, ... }:
{
  options.nucleus.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          homeDirectory = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path to the user's home directory";
          };
          shell = lib.mkOption {
            type = lib.types.path;
            description = "Path to the user's login shell";
          };
          isPrimary = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user receives secret materialization";
          };
        };
      }
    );
    default = {
      admin = {
        homeDirectory = "/Users/admin";
        shell = lib.mkDefault /run/current-system/sw/bin/zsh;
        isPrimary = true;
      };
    };
    description = "Registry of users managed by this configuration";
  };
}
