# modules/windows/power.ps1 — Power policy parity helpers for Windows.
#
# Applies a remote-access-friendly power profile with an explicit cleanup path
# when disabled.

function Sync-PowerPolicy {
  <#
  .SYNOPSIS
    Converges active Windows power-scheme values for cross-host parity.

  .DESCRIPTION
    Applies settings on the currently active power scheme matching the macOS and
    NixOS power posture:
      - AC display timeout:   1 minute  (matches macOS pmset -c displaysleep 1)
      - Battery display timeout: 1 minute (matches NixOS idle-delay = 60)
      - AC lid close action: Do Nothing (keep unattended work alive with lid shut)
      - Battery lid close action: Do Nothing (same behavior on battery)
      - AC system sleep:   Never  (matches macOS/NixOS no-sleep-on-AC for remote access)
      - Battery system sleep: Never  (disabled so remote-desktop sessions survive on battery)
      - AC disk timeout:      Never  (matches macOS pmset -c disksleep 0)
      - Battery disk timeout: Never  (matches macOS pmset -b disksleep 0)
      - TCP keepalive: 60 s idle before first probe (matches macOS pmset tcpkeepalive=1)
      - Wake-on-LAN:   enabled on all physical adapters (matches macOS pmset womp=1)

    Battery system sleep is set to Never so remote-desktop sessions (Chrome
    Remote Desktop, Windows built-in RDP, Parsec) are not disconnected when the
    machine is on battery.  Sleeping on battery breaks active sessions and
    prevents new connections; keeping sleep disabled matches the always-on
    posture of AC power and aligns with the three-protocol remote-desktop
    baseline.

    Lid switch close action is set to Do Nothing on both AC and battery because
    Windows does not inherit "never sleep" from standby timers when the user
    explicitly closes the lid.  Without this, the laptop can still suspend the
    instant the panel shuts, which pauses long-running AI jobs and drops the
    network even though the idle timers say to stay awake.

    TCP keepalive (KeepAliveTime registry value) is set to 60,000 ms so
    persistent SSH tunnels and remote-desktop connections remain alive through
    idle periods without requiring application-level keepalive configuration.
    Mirrors macOS pmset tcpkeepalive=1 and NixOS net.ipv4.tcp_keepalive_time=60.

    Wake-on-LAN is enabled on all physical network adapters so the machine can
    be woken remotely via magic-packet while sleeping.  Adapters that do not
    support WoL (for example USB tethering or virtual adapters) log a warning
    rather than throwing; the hardware default is preserved for those adapters.
    Mirrors macOS pmset womp=1.

    When disabled, values are reset to Windows defaults:
      - AC display timeout:   10 minutes
      - Battery display timeout: 5 minutes
      - AC lid close action:  Sleep
      - Battery lid close action: Sleep
      - AC system sleep:     25 minutes
      - Battery system sleep:   25 minutes
      - AC disk timeout:     20 minutes
      - Battery disk timeout:   10 minutes
      - TCP keepalive:       removed (Windows reverts to system default ~2 hours)
      - Wake-on-LAN:         not altered (hardware default preserved on disable)

    This function updates only managed values on the active scheme.

  .PARAMETER Enabled
    Whether cross-host power parity should be enforced. Mandatory: caller must
    explicitly choose true (apply managed power policy) or false (reset to
    Windows defaults). No implicit default is permitted so the caller is always
    aware of what state change they are authorizing.

  .EXAMPLE
    Sync-PowerPolicy -Enabled:$true

  .EXAMPLE
    Sync-PowerPolicy -Enabled:$false
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
    <#
    .SYNOPSIS
      Runs powercfg and throws on non-zero exit.

    .DESCRIPTION
      Centralizes powercfg exit-code validation so hidden lid-action writes and
      ordinary timeout updates fail fast with an operation-specific message.

    .PARAMETER Arguments
      The exact argument array forwarded to powercfg.exe.

    .PARAMETER FailureMessage
      Human-readable context appended to the thrown error when powercfg fails.

    .EXAMPLE
      Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-ac', '0') -FailureMessage 'Failed to disable AC system sleep.'
    #>
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

  # TCP keepalive is a registry value, not a powercfg setting.
  # KeepAliveTime controls the idle period in milliseconds before the first
  # keepalive probe is issued; Windows reverts to its built-in default
  # (~7,200,000 ms / 2 hours) when the value is absent.
  $tcpParamsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

  if ($Enabled) {
    # Cross-host parity mode: align display, system sleep, and disk sleep
    # with macOS pmset and NixOS logind/auto-cpufreq posture.
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-ac', '1') -FailureMessage 'Failed to set AC display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-dc', '1') -FailureMessage 'Failed to set battery display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setacvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0') -FailureMessage 'Failed to set AC lid close action to Do Nothing.'
    Invoke-PowerCfgChecked -Arguments @('/setdcvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0') -FailureMessage 'Failed to set battery lid close action to Do Nothing.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-ac', '0') -FailureMessage 'Failed to disable AC system sleep.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-dc', '0') -FailureMessage 'Failed to disable battery system sleep.'
    # Disk timeout: prevent automatic disk spindown to mirror macOS disksleep=0.
    # Disk sleep during a remote session causes visible latency spikes when the
    # disk must spin up again mid-operation; keeping it always-on reduces jitter.
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-ac', '0') -FailureMessage 'Failed to disable AC disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-dc', '0') -FailureMessage 'Failed to disable battery disk timeout.'
    # Hidden per-scheme settings only become live after the scheme is re-set as
    # active. Re-applying the current scheme is a no-op for users but forces the
    # new lid-action indexes to take effect immediately.
    Invoke-PowerCfgChecked -Arguments @('/setactive', $activeSchemeGuid) -FailureMessage 'Failed to reactivate the current power scheme after lid-action changes.'

    # TCP keepalive: issue keepalive probes after 60 s of idle TCP so persistent
    # SSH tunnels and remote-desktop sessions survive idle periods without being
    # torn down by intermediate network equipment.  Mirrors macOS tcpkeepalive=1
    # and NixOS tcp_keepalive_time=60.  KeepAliveTime is in milliseconds.
    Set-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime' -Value 60000 -Type DWord

    # Wake-on-LAN: enable magic-packet wake on all physical network adapters so
    # the machine can be woken remotely while sleeping.  Mirrors macOS womp=1.
    # Adapters that do not support WoL (USB tethering, virtual NICs) are expected
    # to return an error from Set-NetAdapterPowerManagement; those errors are
    # intentionally suppressed and replaced with a warning because they are benign
    # capability mismatches, not configuration failures.  $? is checked afterward
    # so genuine unexpected failures (e.g. access denied) still surface via the
    # warning path.
    $physicalAdapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($adapter in $physicalAdapters) {
      $pm = $adapter | Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue
      if ($null -eq $pm) {
        Write-Warning "power: could not read power management for adapter '$($adapter.Name)'; skipping WoL."
        continue
      }
      if ($pm.WakeOnMagicPacket -ne 'Enabled') {
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
    # Windows defaults: restore to standard Windows Home power scheme values.
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-ac', '10') -FailureMessage 'Failed to restore AC display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'monitor-timeout-dc', '5') -FailureMessage 'Failed to restore battery display timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setacvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '1') -FailureMessage 'Failed to restore AC lid close action to Sleep.'
    Invoke-PowerCfgChecked -Arguments @('/setdcvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '1') -FailureMessage 'Failed to restore battery lid close action to Sleep.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-ac', '25') -FailureMessage 'Failed to restore AC system sleep timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'standby-timeout-dc', '25') -FailureMessage 'Failed to restore battery system sleep timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-ac', '20') -FailureMessage 'Failed to restore AC disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/change', 'disk-timeout-dc', '10') -FailureMessage 'Failed to restore battery disk timeout.'
    Invoke-PowerCfgChecked -Arguments @('/setactive', $activeSchemeGuid) -FailureMessage 'Failed to reactivate the current power scheme after restoring defaults.'

    # Remove the managed KeepAliveTime value; Windows reverts to its built-in
    # default (~2 hours) when the value is absent from the registry.
    if (Get-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime' -ErrorAction SilentlyContinue) {
      Remove-ItemProperty -Path $tcpParamsPath -Name 'KeepAliveTime'
    }

    # WoL state is not reversed on disable: disabling managed power parity
    # should not actively remove inbound remote wake capability.  The hardware
    # default for each adapter is preserved as-is.
  }
}
