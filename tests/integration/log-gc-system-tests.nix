# tests/integration/log-gc-system-tests.nix — Content assertions for root system log rotation.

let
  inherit (import ../lib.nix) containsRegex;

  logGcSystemShText = builtins.readFile ../../src/scripts/services/log-gc-system.sh;
  logGcSystemPs1Text = builtins.readFile ../../src/scripts/services/log-gc-system.ps1;
  macosNixText = builtins.readFile ../../src/modules/macos.nix;
  nixosActivationText = builtins.readFile ../../src/hosts/NixOS/activation.nix;
  schedulerText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;
in

# --- service scripts ---
assert containsRegex "rotate_logs_in_directory" logGcSystemShText;
assert containsRegex "nucleus_system_log_dir" logGcSystemShText;
assert containsRegex "Invoke-LogRotation" logGcSystemPs1Text;
assert containsRegex "Get-NucleusSystemLogDir" logGcSystemPs1Text;

# --- macOS launchd daemon ---
assert containsRegex "launchd.daemons.\"log-gc-system\"" macosNixText;
assert containsRegex "nucleus-log-gc-system" macosNixText;

# --- NixOS systemd timer ---
assert containsRegex "systemd.services.\"nucleus-log-gc-system\"" nixosActivationText;
assert containsRegex "systemd.timers.\"nucleus-log-gc-system\"" nixosActivationText;

# --- Windows scheduled task ---
assert containsRegex "TaskName: log-gc-system" schedulerText;
assert containsRegex "log-gc-system.ps1" schedulerText;
assert containsRegex "RunWithHighestPrivileges: true" schedulerText;

# --- rotate_log_file skips unwritable logs ---
assert containsRegex "skipping log rotation for unwritable" libShText;

{
}
