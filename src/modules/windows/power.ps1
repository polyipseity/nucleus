# modules/windows/power.ps1 — Power policy parity helpers for Windows.
#
# Applies a remote-access-friendly power profile with an explicit cleanup path
# when disabled.

function Sync-NucleusPowerPolicy {
  <#
  .SYNOPSIS
    Converges active Windows power-scheme values used for remote-access parity.

  .DESCRIPTION
    Applies settings on the currently active power scheme to keep the machine
    available for remote sessions while preserving display sleep behavior:
      - AC sleep timeout: never
      - Battery sleep timeout: never
      - AC display timeout: 1 minute
      - Battery display timeout: 1 minute

    When disabled, values are restored to a conservative fallback baseline:
      - AC sleep timeout: 30 minutes
      - Battery sleep timeout: 15 minutes
      - AC display timeout: 10 minutes
      - Battery display timeout: 5 minutes

    This function updates only managed values on the active scheme.

  .PARAMETER Enabled
    Whether remote-access-oriented power parity should be enforced.

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
    & $powercfg /change monitor-timeout-ac 1
    & $powercfg /change monitor-timeout-dc 1
    & $powercfg /change standby-timeout-ac 0
    & $powercfg /change standby-timeout-dc 0
  }
  else {
    & $powercfg /change monitor-timeout-ac 10
    & $powercfg /change monitor-timeout-dc 5
    & $powercfg /change standby-timeout-ac 30
    & $powercfg /change standby-timeout-dc 15
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply managed Windows power policy. Exit code: $LASTEXITCODE"
  }
}
