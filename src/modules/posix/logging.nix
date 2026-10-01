# Logging paths, rotation, and sanitization shared across service modules.
{
  lib,
  pkgs,
  hostName ? null,
  ...
}:
let
  inherit (lib) mkOption types;
  loggingPaths = import ../lib/logging-paths.nix { inherit lib pkgs hostName; };
in
{
  options.nucleus.logging = {
    logDir = mkOption {
      type = types.str;
      default = loggingPaths.logDirTemplate;
      defaultText = lib.literalExpression "services.json \$logging.${loggingPaths.hostKey}.logDir";
      description = "User-level log directory for nucleus services.";
    };

    # macOS 26+ SIP blocks non-root launchd daemons from writing to /Library/Logs/
    # (EX_CONFIG 78), so the SYSTEM root is /Library/Application Support/nucleus/logs.
    # The same restriction blocks unsigned store binaries at boot, hence the
    # /bin/sh wrapper documented in
    # .agents/instructions/macos-service-hardening.instructions.md.
    systemLogDir = mkOption {
      type = types.str;
      default = loggingPaths.systemLogDir;
      defaultText = lib.literalExpression "services.json \$logging.${loggingPaths.hostKey}.systemLogDir";
      description = "System-level log directory for nucleus services.";
    };

    # Runtime tooling reads services.schema.json, not these options; they exist for
    # build-time references and per-service overrides come from services.json.
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

      # WHY: retention is not derived from modules.gc.expiry. They were one variable,
      # NUCLEUS_GC_EXPIRY, so raising GC retention silently raised log retention.
      expiry = mkOption {
        type = types.str;
        default = "7d";
        description = "Age at which rotated log archives are deleted. Independent of modules.gc.expiry by design, and read at runtime via NUCLEUS_LOG_EXPIRY (resolved by src/scripts/lib/log-expiry.sh).";
      };
    };

    sanitize = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to strip control characters (ANSI escapes, \\r) from log output (runtime source: services.schema.json definitions.loggingEntry.properties).";
    };

    # logging.capture is read by scripts/svc.sh, scripts/gc.sh/ps1, and the
    # apply.sh health check. It is not wired to unit output paths: those are
    # hardcoded per module as StandardOutPath/StandardErrorPath (macOS) or
    # journald (NixOS).
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
