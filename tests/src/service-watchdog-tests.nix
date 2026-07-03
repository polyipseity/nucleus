# tests/src/service-watchdog-tests.nix — Schema and invariant tests for service
# watchdog.
#
# Validates that the watchdog scripts (service-watchdog.sh,
# service-watchdog.ps1), platform scheduling configs (macOS launchd agent,
# NixOS systemd timer, Windows DSC task), and flake wiring contain the
# required structural elements.
#
# Run with: nix-instantiate --eval tests/src/service-watchdog-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  watchdogShText = builtins.readFile ../../scripts/service-watchdog.sh;
  watchdogPs1Text = builtins.readFile ../../scripts/service-watchdog.ps1;
  flakeText = builtins.readFile ../../src/flake.nix;
  macosNixText = builtins.readFile ../../src/modules/macos.nix;
  nixosActivationText = builtins.readFile ../../src/hosts/NixOS/activation.nix;
  windowsSchedulerDscText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
  servicesJsonText = builtins.readFile ../../src/modules/services.json;
in

# --- services.json structural assertions ---
assert containsRegex ''"service-watchdog"'' servicesJsonText;
assert containsRegex ''"local.service-watchdog"'' servicesJsonText;
assert containsRegex ''"nucleus-service-watchdog.service"'' servicesJsonText;
assert containsRegex ''"\\\\nucleus\\\\service-watchdog"'' servicesJsonText;

# --- service-watchdog.sh structural assertions ---
assert containsRegex "#!/usr/bin/env bash" watchdogShText;
assert containsRegex "set -euo pipefail" watchdogShText;
assert containsRegex "services.json" watchdogShText;
assert containsRegex "require_command jq" watchdogShText;
assert containsRegex "recover_launchctl" watchdogShText;
assert containsRegex "check_service_macos" watchdogShText;
assert containsRegex "check_service_nixos" watchdogShText;
assert containsRegex "read_watchdog_services" watchdogShText;
assert containsRegex "log_restart" watchdogShText;
assert containsRegex "launchctl_target" watchdogShText;

# --- service-watchdog.sh macOS recovery patterns ---
assert containsRegex "state = running" watchdogShText;
assert containsRegex "state = spawn scheduled" watchdogShText;
assert containsRegex "state = waiting" watchdogShText;
assert containsRegex "last exit code = 78" watchdogShText;
assert containsRegex "Service is not found" watchdogShText;
assert containsRegex "launchctl bootout" watchdogShText;
assert containsRegex "launchctl bootstrap" watchdogShText;

# --- service-watchdog.sh NixOS recovery patterns ---
assert containsRegex "systemctl.*is-active" watchdogShText;
assert containsRegex "systemctl.*reset-failed" watchdogShText;
assert containsRegex "systemctl.*restart" watchdogShText;

# --- service-watchdog.sh platform filtering ---
assert containsRegex "socketActivated" watchdogShText;
assert containsRegex "prefixMatch" watchdogShText;
assert containsRegex "exit 0" watchdogShText;

# --- service-watchdog.ps1 structural assertions ---
assert containsRegex ".SYNOPSIS" watchdogPs1Text;
assert containsRegex "services.json" watchdogPs1Text;
assert containsRegex "Write-RestartLog" watchdogPs1Text;
assert containsRegex "Test-NativeService" watchdogPs1Text;
assert containsRegex "Test-ScheduledTask" watchdogPs1Text;
assert containsRegex "Get-Service" watchdogPs1Text;
assert containsRegex "Restart-Service" watchdogPs1Text;
assert containsRegex "Get-ScheduledTask" watchdogPs1Text;
assert containsRegex "Start-ScheduledTask" watchdogPs1Text;
assert containsRegex "socketActivated" watchdogPs1Text;
assert containsRegex "prefixMatch" watchdogPs1Text;

# --- macOS launchd agent config ---
assert containsRegex "local.service-watchdog" macosNixText;
assert containsRegex "StartInterval = 300" macosNixText;
assert containsRegex "RunAtLoad = true" macosNixText;
assert containsRegex "service-watchdog" macosNixText;
assert containsRegex "service-watchdog/stdout.log" macosNixText;

# --- NixOS systemd timer config ---
assert containsRegex "nucleus-service-watchdog" nixosActivationText;
assert containsRegex "OnUnitActiveSec" nixosActivationText;
assert containsRegex "5min" nixosActivationText;
assert containsRegex "timers.target" nixosActivationText;
assert containsRegex "oneshot" nixosActivationText;
assert containsRegex "nucleus-service-watchdog" nixosActivationText;
assert containsRegex "pkgs.jq" nixosActivationText;
assert containsRegex "NUCLEUS_REPO_ROOT" nixosActivationText;

# --- Windows DSC task config ---
assert containsRegex "TaskName: service-watchdog" windowsSchedulerDscText;
assert containsRegex "TaskPath: \\\\nucleus\\\\" windowsSchedulerDscText;
assert containsRegex "PT5M" windowsSchedulerDscText;
assert containsRegex "service-watchdog.ps1" windowsSchedulerDscText;
assert containsRegex "NUCLEUS_REPO_ROOT" windowsSchedulerDscText;
assert containsRegex "RunWithHighestPrivileges: true" windowsSchedulerDscText;

# --- Flake wiring ---
assert containsRegex "nucleus-service-watchdog" flakeText;
assert containsRegex ''name = "service-watchdog"'' flakeText;
assert containsRegex "nucleusApps = nucleusAppsLinux" flakeText;
assert containsRegex "pkgs.jq" flakeText;

# --- Services.json integration ---
assert containsRegex ''\$schema.*services\.schema\.json'' servicesJsonText;
true
