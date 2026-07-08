# tests/integration/log-rotation-tests.nix — Content assertions for the
# cross-platform log rotation feature.
#
# Verifies that the rotation functions, GC wiring, services.json defaults,
# and option doc references are all consistent and present.
#
# Run with: nix-instantiate --eval tests/integration/log-rotation-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  libShText = builtins.readFile ../../src/scripts/lib.sh;
  gcShText = builtins.readFile ../../scripts/gc.sh;
  gcPs1Text = builtins.readFile ../../scripts/gc.ps1;
  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  loggingNixText = builtins.readFile ../../src/modules/logging.nix;
  healthCheckShText = builtins.readFile ../../scripts/health-check.sh;
in

# --- src/scripts/lib.sh: log rotation functions ---
assert containsRegex "rotate_log_file\\(\\)" libShText;
assert containsRegex "Copy-truncate a single log file" libShText;
assert containsRegex "rotate_logs_in_directory\\(\\)" libShText;
assert containsRegex "Iterate over all \\\*.log files" libShText;
assert containsRegex "cp .*_rlf_logfile.*_rlf_logfile\\.1" libShText;
assert containsRegex ": > .*_rlf_logfile" libShText;

# --- scripts/gc.sh: log-gc flags ---
assert containsRegex "--log-gc.*--no-log-gc" gcShText;
assert containsRegex "log_gc=true" gcShText;
assert containsRegex "gc_logs\\(\\)" gcShText;
assert containsRegex "rotate_logs_in_directory" gcShText;

# --- scripts/gc.sh: reads services.json ---
assert containsRegex "services\\.json" gcShText;
assert containsRegex "[$]defaults" gcShText;

# --- scripts/gc.ps1: -NoLogGc switch and log rotation import ---
assert containsRegex "NoLogGc" gcPs1Text;
assert containsRegex "LogMaxSize" gcPs1Text;
assert containsRegex "LogMaxFiles" gcPs1Text;
assert containsRegex "LogCompress" gcPs1Text;
assert containsRegex "Invoke-LogManagement\\.ps1" gcPs1Text;
assert containsRegex "Invoke-LogRotation" gcPs1Text;
assert containsRegex "Get-NucleusLogDir" gcPs1Text;
assert containsRegex "NUCLEUS_GC_NO_LOG_GC" gcPs1Text;

# --- src/modules/services.json: $defaults.logging block ---
assert containsRegex "[$]defaults" servicesJsonText;
assert containsRegex ''"maxSize": 10485760'' servicesJsonText;
assert containsRegex ''"maxFiles": 4'' servicesJsonText;
assert containsRegex ''"compress": true'' servicesJsonText;

# --- src/modules/logging.nix: option docs point to services.json ---
assert containsRegex "services\\.json" loggingNixText;
assert containsRegex "runtime source: services\\.json" loggingNixText;

# --- scripts/health-check.sh: reads $defaults.logging.maxSize ---
assert containsRegex "[$]defaults" healthCheckShText;
true
