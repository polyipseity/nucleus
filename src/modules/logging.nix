# Logging paths, rotation, and sanitization shared across service modules.
{ lib, pkgs, hostName ? null, ... }:
let
  inherit (lib) mkOption types;
  loggingPaths = import ./lib/logging-paths.nix { inherit lib pkgs hostName; };
in
{
  options.nucleus.logging = {
    logDir = mkOption {
      type = types.str;
      default = loggingPaths.logDirTemplate;
      defaultText = lib.literalExpression "services.json \$logging.${loggingPaths.hostKey}.logDir";
      description = "User-level log directory for nucleus services.";
    };

    # macOS SIP log path restriction: on macOS 26+, SIP blocks non-root
    # launchd daemons from writing to /Library/Logs/ (EX_CONFIG 78).
    # /Users/Shared/nucleus/logs is the approved alternative.
    # /tmp/ works for testing; /Library/Logs/ is blocked.
    # The same SIP restriction also blocks unsigned binary execution at boot;
    # all MacBook daemons work around it via /bin/sh wrapper
    # (.agents/instructions/macos-launchd-sip.instructions.md).
    systemLogDir = mkOption {
      type = types.str;
      default = loggingPaths.systemLogDir;
      defaultText = lib.literalExpression "services.json \$logging.${loggingPaths.hostKey}.systemLogDir";
      description = "System-level log directory for nucleus services.";
    };

    # Rotation parameters are now defined in services.json $defaults.logging
    # and consumed at runtime by scripts/gc.sh and scripts/gc.ps1.
    # The Nix build-time options are retired in favor of the JSON source of
    # truth, which is readable by both POSIX and Windows tooling.
    rotation = {
      maxSize = mkOption {
        type = types.int;
        default = 10000000; # bytes
        description = "Maximum log file size in bytes before rotation (runtime source: services.json).";
      };

      maxFiles = mkOption {
        type = types.int;
        default = 4;
        description = "Number of rotated archives to keep (runtime source: services.json).";
      };

      compress = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to compress rotated archives with gzip (runtime source: services.json).";
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
