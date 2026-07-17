# tests/integration/log-rotation-tests.nix — Content assertions for cross-platform log rotation.

let
  inherit (import ../lib.nix) containsRegex flatten;

  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;
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

# --- scripts/gc.sh: git-template-gc flags ---
assert containsRegex "--git-template-gc.*--no-git-template-gc" gcShText;
assert containsRegex "git_template_gc=true" gcShText;
assert containsRegex "gc_git_templates_if_present\\(\\)" gcShText;
assert containsRegex "stale \.git boilerplate" gcShText;
assert containsRegex "rm.*hooks.*\\.sample" gcShText;
assert containsRegex "rm.*description" gcShText;
assert containsRegex "find.*dev_root.*-name.*\\.git" gcShText;

# --- scripts/gc.ps1: -NoGitTemplateGc switch and Clear-GitTemplateFiles ---
assert containsRegex "NoGitTemplateGc" gcPs1Text;
assert containsRegex "Clear-GitTemplateFiles" gcPs1Text;
assert containsRegex "NUCLEUS_GC_NO_GIT_TEMPLATE_GC" gcPs1Text;
assert containsRegex "\\.sample" gcPs1Text;
assert containsRegex "Git template boilerplate" gcPs1Text;
assert containsRegex "description" gcPs1Text;

# --- src/modules/services.json: $defaults.logging block ---
assert containsRegex "[$]defaults" servicesJsonText;
assert containsRegex ''"maxSize": 10000000'' servicesJsonText;
assert containsRegex ''"maxFiles": 4'' servicesJsonText;
assert containsRegex ''"compress": true'' servicesJsonText;

# --- src/modules/services.json: dirs and runAsUser fields ---
assert containsRegex ''"dirs"'' servicesJsonText;
assert containsRegex ''"runAsUser": true'' servicesJsonText;

# --- src/modules/logging.nix: option docs point to services.json ---
assert containsRegex "services\\.json" loggingNixText;
assert containsRegex "runtime source: services\\.json" loggingNixText;

# --- scripts/health-check.sh: reads $defaults.logging.maxSize ---
assert containsRegex "[$]defaults" healthCheckShText;
{
  success = true;
  message = "Log rotation content assertions passed";
}
