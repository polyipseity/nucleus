# modules/logging.nix — Centralized logging configuration for nucleus services.
#
# Canonical source for log directory paths, rotation settings, and sanitization
# policy consumed by all service modules.
#
# Import this module at both the system level (in host/default.nix) and the
# user level (in home.nix) to make options available everywhere.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
in
{
  options.nucleus.logging = {
    logDir = mkOption {
      type = types.str;
      default = if pkgs.stdenv.isDarwin then "~/Library/Logs/nucleus" else "~/.local/state/nucleus/log";
      defaultText = lib.literalExpression ''if pkgs.stdenv.isDarwin then "~/Library/Logs/nucleus" else "~/.local/state/nucleus/log"'';
      description = "User-level log directory for nucleus services.";
    };

    systemLogDir = mkOption {
      type = types.str;
      default = if pkgs.stdenv.isDarwin then "/Users/Shared/nucleus/logs" else "/var/log/nucleus";
      defaultText = lib.literalExpression ''if pkgs.stdenv.isDarwin then "/Users/Shared/nucleus/logs" else "/var/log/nucleus"'';
      description = "System-level log directory for nucleus services.";
    };

    rotation = {
      maxSize = mkOption {
        type = types.int;
        default = 10485760; # 10 MB
        description = "Maximum log file size in bytes before rotation.";
      };

      maxFiles = mkOption {
        type = types.int;
        default = 4;
        description = "Number of rotated archives to keep.";
      };

      compress = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to compress rotated archives with gzip.";
      };
    };

    sanitize = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to strip control characters (ANSI escapes, \\r) from log output.";
    };

    captureDefault = mkOption {
      type = types.enum [
        "all"
        "stdout"
        "stderr"
        "none"
      ];
      default = "all";
      description = "Default log capture mode for services without an explicit logging.capture setting.";
    };
  };
}
