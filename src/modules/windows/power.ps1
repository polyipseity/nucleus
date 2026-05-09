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
      - AC system sleep:     25 minutes
      - Battery system sleep:   25 minutes
      - AC disk timeout:     20 minutes
      - Battery disk timeout:   10 minutes
      - TCP keepalive:       removed (Windows reverts to system default ~2 hours)
      - Wake-on-LAN:         not altered (hardware default preserved on disable)

    This function updates only managed values on the active scheme.

  .PARAMETER Enabled
    Whether cross-host power parity should be enforced.

  .EXAMPLE
    Sync-PowerPolicy -Enabled:$true

  .EXAMPLE
    Sync-PowerPolicy -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $powercfg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe'
  if (-not (Test-Path -Path $powercfg)) {
    throw "powercfg executable not found at '$powercfg'."
  }

  # TCP keepalive is a registry value, not a powercfg setting.
  # KeepAliveTime controls the idle period in milliseconds before the first
  # keepalive probe is issued; Windows reverts to its built-in default
  # (~7,200,000 ms / 2 hours) when the value is absent.
  $tcpParamsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

  if ($Enabled) {
    # Cross-host parity mode: align display, system sleep, and disk sleep
    # with macOS pmset and NixOS logind/auto-cpufreq posture.
    & $powercfg /change monitor-timeout-ac 1
    & $powercfg /change monitor-timeout-dc 1
    & $powercfg /change standby-timeout-ac 0
    & $powercfg /change standby-timeout-dc 0
    # Disk timeout: prevent automatic disk spindown to mirror macOS disksleep=0.
    # Disk sleep during a remote session causes visible latency spikes when the
    # disk must spin up again mid-operation; keeping it always-on reduces jitter.
    & $powercfg /change disk-timeout-ac 0
    & $powercfg /change disk-timeout-dc 0

    if ($LASTEXITCODE -ne 0) {
      throw "Failed to apply managed Windows power policy. Exit code: $LASTEXITCODE"
    }

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
        Write-Warning "nucleus: could not read power management for adapter '$($adapter.Name)'; skipping WoL."
        continue
      }
      if ($pm.WakeOnMagicPacket -ne 'Enabled') {
        $adapter | Set-NetAdapterPowerManagement -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue
        if ($?) {
          Write-Verbose "nucleus: enabled Wake-on-LAN for adapter '$($adapter.Name)'."
        }
        else {
          Write-Warning "nucleus: failed to enable Wake-on-LAN for adapter '$($adapter.Name)'; adapter may not support WoL."
        }
      }
    }
  }
  else {
    # Windows defaults: restore to standard Windows Home power scheme values.
    & $powercfg /change monitor-timeout-ac 10
    & $powercfg /change monitor-timeout-dc 5
    & $powercfg /change standby-timeout-ac 25
    & $powercfg /change standby-timeout-dc 25
    & $powercfg /change disk-timeout-ac 20
    & $powercfg /change disk-timeout-dc 10

    if ($LASTEXITCODE -ne 0) {
      throw "Failed to restore Windows power policy defaults. Exit code: $LASTEXITCODE"
    }

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
