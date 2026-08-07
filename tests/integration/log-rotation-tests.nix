# tests/integration/log-rotation-tests.nix — Content assertions for cross-platform log rotation.

let
  inherit (import ../lib.nix) containsRegex;

  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;
  gcShText = builtins.readFile ../../scripts/gc.sh;
  gcPs1Text = builtins.readFile ../../scripts/gc.ps1;
  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  servicesSchemaText = builtins.readFile ../../src/modules/services.schema.json;
  loggingNixText = builtins.readFile ../../src/modules/logging.nix;
  healthCheckShText = builtins.readFile ../../scripts/health-check.sh;
  posixBaseNixText = builtins.readFile ../../src/modules/posix-base.nix;
  macosNixText = builtins.readFile ../../src/modules/macos.nix;
  linuxNixText = builtins.readFile ../../src/modules/linux.nix;
  nixosActivationText = builtins.readFile ../../src/hosts/NixOS/activation.nix;
  schedulerDscText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
  gcSweepShText = builtins.readFile ../../src/scripts/services/gc-sweep.sh;
in

# --- src/scripts/lib.sh: log rotation functions ---
assert containsRegex "case \"\\\$_nelp_path\" in" libShText;
assert containsRegex "nucleus_expand_log_path" libShText;
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

# --- scripts/gc.sh: reads defaults from schema ---
assert containsRegex "services\.schema\.json" gcShText;
assert containsRegex "definitions\.loggingEntry\.properties\.maxSize\.default" gcShText;

# --- scripts/gc.ps1: -NoLogGc switch and log rotation import ---
assert containsRegex "NoLogGc" gcPs1Text;
assert containsRegex "LogMaxSize" gcPs1Text;
assert containsRegex "LogMaxFiles" gcPs1Text;
assert containsRegex "LogCompress" gcPs1Text;
assert containsRegex "Invoke-LogManagement\\.ps1" gcPs1Text;
assert containsRegex "Invoke-LogRotation" gcPs1Text;
assert containsRegex "Get-NucleusLogDir" gcPs1Text;
assert containsRegex "NUCLEUS_GC_NO_LOG_GC" gcPs1Text;

# --- scripts/gc.sh: git-cache-gc flags ---
assert containsRegex "--git-cache-gc.*--no-git-cache-gc" gcShText;
assert containsRegex "git_cache_gc" gcShText;
assert containsRegex "gc_git_cache_if_present\\(\\)" gcShText;

# --- scripts/gc.ps1: -NoGitCacheGc switch and Clear-GitCache ---
assert containsRegex "NoGitCacheGc" gcPs1Text;
assert containsRegex "Clear-GitCache" gcPs1Text;
assert containsRegex "NUCLEUS_GC_NO_GIT_CACHE_GC" gcPs1Text;

# --- src/modules/services.schema.json: loggingEntry defaults ---
assert containsRegex ''"default": 10000000'' servicesSchemaText;
assert containsRegex ''"default": 4'' servicesSchemaText;
assert containsRegex ''"default": true'' servicesSchemaText;

# --- src/modules/services.json: dirs and runAsUser fields ---
assert containsRegex ''"dirs"'' servicesJsonText;
assert containsRegex ''"runAsUser": true'' servicesJsonText;

# --- src/modules/logging.nix: option docs point to services.json ---
assert containsRegex "services\\.json" loggingNixText;
assert containsRegex "runtime source: services\\.json" loggingNixText;

# --- scripts/health-check.sh: reads schema for logging defaults ---
assert containsRegex "services\.schema\.json" healthCheckShText;
assert containsRegex "definitions\.loggingEntry\.properties\.maxSize\.default" healthCheckShText;

# --- schedulers wire modules.gc.expiry as NUCLEUS_GC_EXPIRY ---
assert containsRegex "NUCLEUS_GC_EXPIRY = config.modules.gc.expiry" posixBaseNixText;
assert containsRegex "NUCLEUS_GC_EXPIRY = config.modules.gc.expiry" macosNixText;
assert containsRegex "NUCLEUS_GC_EXPIRY=\$\{config.modules.gc.expiry\}" linuxNixText;
assert containsRegex "NUCLEUS_GC_EXPIRY=\$\{config.modules.gc.expiry\}" nixosActivationText;
assert containsRegex "NUCLEUS_GC_EXPIRY = '7d'" schedulerDscText;

# --- gc-sweep documents intentional overlap with daily log GC ---
assert containsRegex "overlap is intentional and idempotent" gcSweepShText;
{
  success = true;
  message = "Log rotation content assertions passed";
}
