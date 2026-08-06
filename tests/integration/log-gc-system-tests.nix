# tests/integration/log-gc-system-tests.nix — Content assertions for nucleus log GC schedulers.

let
  inherit (import ../lib.nix) containsRegex;

  logGcSystemShText = builtins.readFile ../../src/scripts/services/log-gc-system.sh;
  logGcSystemPs1Text = builtins.readFile ../../src/scripts/services/log-gc-system.ps1;
  logGcUserShText = builtins.readFile ../../src/scripts/services/log-gc-user.sh;
  logGcUserPs1Text = builtins.readFile ../../src/scripts/services/log-gc-user.ps1;
  posixBaseNixText = builtins.readFile ../../src/modules/posix-base.nix;
  macosNixText = builtins.readFile ../../src/modules/macos.nix;
  linuxNixText = builtins.readFile ../../src/modules/linux.nix;
  nixosActivationText = builtins.readFile ../../src/hosts/NixOS/activation.nix;
  schedulerText = builtins.readFile ../../src/hosts/Windows/system/scheduler.dsc.yml;
  libShText = builtins.readFile ../../src/scripts/lib/lib.sh;
in

# --- service scripts ---
assert containsRegex "rotate_logs_in_directory" logGcSystemShText;
assert containsRegex "expire_logs_in_directory" logGcSystemShText;
assert containsRegex "nucleus_system_log_dir" logGcSystemShText;
assert containsRegex "Invoke-LogRotation" logGcSystemPs1Text;
assert containsRegex "Invoke-LogExpiry" logGcSystemPs1Text;
assert containsRegex "Get-NucleusSystemLogDir" logGcSystemPs1Text;

assert containsRegex "rotate_logs_in_directory" logGcUserShText;
assert containsRegex "expire_logs_in_directory" logGcUserShText;
assert containsRegex "nucleus_log_dir" logGcUserShText;
assert containsRegex "Invoke-LogRotation" logGcUserPs1Text;
assert containsRegex "Invoke-LogExpiry" logGcUserPs1Text;

# --- macOS launchd ---
assert containsRegex "launchd.daemons.\"log-gc-system\"" posixBaseNixText;
assert containsRegex "nucleus-log-gc-system" posixBaseNixText;
assert containsRegex "launchd.agents.\"log-gc-user\"" macosNixText;
assert containsRegex "nucleus-log-gc-user" macosNixText;

# --- NixOS systemd timers ---
assert containsRegex "systemd.services.\"nucleus-log-gc-system\"" nixosActivationText;
assert containsRegex "systemd.timers.\"nucleus-log-gc-system\"" nixosActivationText;
assert containsRegex "systemd.user.services.\"log-gc-user\"" linuxNixText;
assert containsRegex "systemd.user.timers.\"log-gc-user\"" linuxNixText;

# --- Windows scheduled tasks ---
assert containsRegex "TaskName: log-gc-system" schedulerText;
assert containsRegex "log-gc-system.ps1" schedulerText;
assert containsRegex "RunWithHighestPrivileges: true" schedulerText;
assert containsRegex "TaskName: log-gc-user" schedulerText;
assert containsRegex "log-gc-user.ps1" schedulerText;

# --- rotate_log_file skips unwritable logs ---
assert containsRegex "skipping log rotation for unwritable" libShText;
assert containsRegex "expire_logs_in_directory" libShText;

{
}
