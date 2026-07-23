function Sync-PowerPolicy {
  <#
  .SYNOPSIS
    Converges active Windows power-scheme values for cross-host parity.

  .DESCRIPTION
    Matches macOS and NixOS power posture:
      AC|Battery display timeout: 1 min, lid close: Do Nothing, sleep: Never,
      disk timeout: Never, TCP keepalive: 60 s, Wake-on-LAN: enabled.
    When disabled, resets to Windows defaults.

  .PARAMETER Enabled
    True applies managed power policy; false resets to Windows defaults.

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $powercfg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe'
  if (-not (Test-Path -Path $powercfg)) {
    throw "powercfg executable not found at '$powercfg'."
  }

  # powercfg uses the active power-scheme GUID for hidden lid settings such as
  # LIDACTION.  Resolve it once up front so both convergence and cleanup paths
  # target the same live scheme instead of guessing a vendor-specific default.
  $activeSchemeOutput = & $powercfg /getactivescheme
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve the active Windows power scheme. Exit code: $LASTEXITCODE"
  }

  $activeSchemeText = ($activeSchemeOutput | Out-String).Trim()
  $activeSchemeMatch = [regex]::Match($activeSchemeText, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
  if (-not $activeSchemeMatch.Success) {
    throw "Failed to parse active power scheme GUID from output: $activeSchemeText"
  }

  $activeSchemeGuid = $activeSchemeMatch.Groups[1].Value
  $lidActionSubgroup = 'SUB_BUTTONS'
  $lidActionSetting = 'LIDACTION'

  function Invoke-PowerCfgChecked {
    param(
      [Parameter(Mandatory)]
      [string[]]$Arguments,

      [Parameter(Mandatory)]
      [string]$FailureMessage
    )

    & $powercfg @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "$FailureMessage Exit code: $LASTEXITCODE"
    }
  }

  $tcpParamsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

  if ($Enabled) {
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-ac', '1') -FailureMessage 'Failed to set AC display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-dc', '1') -FailureMessage 'Failed to set battery display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setacvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0') -FailureMessage 'Failed to set AC lid close action to Do Nothing.'
    Invoke-PowerCfgChecked -Arguments @('/setdcvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0') -FailureMessage 'Failed to set battery lid close action to Do Nothing.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-ac', '0') -FailureMessage 'Failed to disable AC system sleep.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-dc', '0') -FailureMessage 'Failed to disable battery system sleep.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-ac', '0') -FailureMessage 'Failed to disable AC disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-dc', '0') -FailureMessage 'Failed to disable battery disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setactive', $activeSchemeGuid) -FailureMessage 'Failed to reactivate the current power scheme after lid-action changes.'

    Set-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime' -Value 60000 -Type DWord

    # check-suppress:suppression_doc: probe — no physical adapters on headless/system.
    $physicalAdapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($adapter in $physicalAdapters) {
      # check-suppress:suppression_doc: probe — adapter may not support power management.
      $pm = $adapter | Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue
      if ($null -eq $pm) {
        Write-Warning "power: could not read power management for adapter '$($adapter.Name)'; skipping WoL."
        continue
      }
      if ($pm.WakeOnMagicPacket -ne 'Enabled') {
        # check-suppress:suppression_doc: best-effort — adapter may not support power management.
        $adapter | Set-NetAdapterPowerManagement -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue
        if ($?) {
          Write-Verbose "power: enabled Wake-on-LAN for adapter '$($adapter.Name)'."
        }
        else {
          Write-Warning "power: failed to enable Wake-on-LAN for adapter '$($adapter.Name)'; adapter may not support WoL."
        }
      }
    }
  }
  else {
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-ac', '10') -FailureMessage 'Failed to restore AC display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-dc', '5') -FailureMessage 'Failed to restore battery display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setacvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '1') -FailureMessage 'Failed to restore AC lid close action to Sleep.'
    Invoke-PowerCfgChecked -Arguments @('/setdcvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '1') -FailureMessage 'Failed to restore battery lid close action to Sleep.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-ac', '25') -FailureMessage 'Failed to restore AC system sleep timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-dc', '25') -FailureMessage 'Failed to restore battery system sleep timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-ac', '20') -FailureMessage 'Failed to restore AC disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-dc', '10') -FailureMessage 'Failed to restore battery disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setactive', $activeSchemeGuid) -FailureMessage 'Failed to reactivate the current power scheme after restoring defaults.'

    # check-suppress:suppression_doc: probe whether KeepAliveTime exists before removing; Get-ItemProperty throws when absent.
    if (Get-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime' -ErrorAction SilentlyContinue) {
      Remove-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime'
    }

  }
}
