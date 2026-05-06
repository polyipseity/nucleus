# modules/windows/power.ps1 — Power policy parity helpers for Windows.
#
# Applies a remote-access-friendly power profile with an explicit cleanup path
# when disabled.

function Sync-NucleusPowerPolicy {
  <#
  .SYNOPSIS
    Converges active Windows power-scheme values for cross-host parity.

  .DESCRIPTION
    Applies settings on the currently active power scheme matching the macOS and
    NixOS power posture:
      - AC display timeout: 1 minute (matches macOS pmset -c displaysleep 1)
      - Battery display timeout: 1 minute (matches NixOS idle-delay = 60)
      - AC system sleep: Never (matches macOS/NixOS no-sleep-on-AC for remote access)
      - Battery system sleep: 1 minute (matches macOS/NixOS for parity)

    This parity ensures that development machines prioritize responsive remote
    access and background-task continuity on AC power, with aggressive display
    and system shutdown when unplugged.

    When disabled, values are reset to Windows defaults:
      - AC display timeout: 10 minutes
      - Battery display timeout: 5 minutes
      - AC system sleep: 25 minutes
      - Battery system sleep: 25 minutes

    This function updates only managed values on the active scheme.

  .PARAMETER Enabled
    Whether cross-host power parity should be enforced.

  .EXAMPLE
    Sync-NucleusPowerPolicy -Enabled:$true

  .EXAMPLE
    Sync-NucleusPowerPolicy -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $powercfg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe'
  if (-not (Test-Path -Path $powercfg)) {
    throw "powercfg executable not found at '$powercfg'."
  }

  if ($Enabled) {
    # Cross-host parity mode: align display and system sleep with macOS/NixOS.
    & $powercfg /change monitor-timeout-ac 1
    & $powercfg /change monitor-timeout-dc 1
    & $powercfg /change standby-timeout-ac 0
    & $powercfg /change standby-timeout-dc 1
  }
  else {
    # Windows defaults: restore to standard Windows Home power scheme.
    & $powercfg /change monitor-timeout-ac 10
    & $powercfg /change monitor-timeout-dc 5
    & $powercfg /change standby-timeout-ac 25
    & $powercfg /change standby-timeout-dc 25
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply managed Windows power policy. Exit code: $LASTEXITCODE"
  }
}
