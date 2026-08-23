# Logging paths, rotation, and sanitization shared across service modules.
{
  lib,
  pkgs,
  hostName ? null,
  ...
}:
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
    # (.agents/instructions/macos-service-hardening.instructions.md).
    systemLogDir = mkOption {
      type = types.str;
      default = loggingPaths.systemLogDir;
      defaultText = lib.literalExpression "services.json \$logging.${loggingPaths.hostKey}.systemLogDir";
      description = "System-level log directory for nucleus services.";
    };

    # Rotation defaults live in services.schema.json definitions.loggingEntry
    # .properties (maxSize 10000000 / maxFiles 4 / compress true / sanitize
    # true) and are consumed at runtime by scripts/gc.sh, scripts/gc.ps1, and
    # scripts/apply.sh (health-check subcommand) (per-service overrides from services.json). The
    # Nix options below mirror those defaults for build-time references only;
    # runtime tooling reads the JSON schema, not these options.
    rotation = {
      maxSize = mkOption {
        type = types.int;
        default = 10000000; # bytes
        description = "Maximum log file size in bytes before rotation (runtime source: services.schema.json definitions.loggingEntry.properties).";
      };

      maxFiles = mkOption {
        type = types.int;
        default = 4;
        description = "Number of rotated archives to keep (runtime source: services.schema.json definitions.loggingEntry.properties).";
      };

      compress = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to compress rotated archives with gzip (runtime source: services.schema.json definitions.loggingEntry.properties).";
      };
    };

    sanitize = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to strip control characters (ANSI escapes, \\r) from log output (runtime source: services.schema.json definitions.loggingEntry.properties).";
    };

    # logging.capture is consumed by runtime tooling only: scripts/svc.sh
    # (log display), scripts/gc.sh/ps1 and scripts/apply.sh (health-check subcommand) (whether a
    # service's logs are rotated and size-checked). It is NOT wired to
    # launchd/systemd unit output paths — those are hardcoded per module via
    # StandardOutPath/StandardErrorPath (macOS) or journald (NixOS), and
    # wiring capture to unit paths is explicitly out of scope.
    captureDefault = mkOption {
      type = types.enum [
        "all"
        "stdout"
        "stderr"
        "none"
      ];
      default = "all";
      description = "Default log capture mode for services without an explicit logging.capture setting (runtime source: services.schema.json definitions.loggingEntry.properties).";
    };
  };
}
