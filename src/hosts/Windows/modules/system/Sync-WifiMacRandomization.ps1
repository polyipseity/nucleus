function Sync-WifiMacRandomization {
  <#
  .SYNOPSIS
    Converges Wi-Fi MAC address randomization for cross-host parity.

  .DESCRIPTION
    Enables per-adapter Wi-Fi MAC address randomization via the
    WlanSvc interface registry key (RandomizationEnabled = 1).
    Mirrors the NixOS networking.networkmanager.wifi.macAddress
    and macOS Private Wi-Fi Address features.

    When disabled, resets RandomizationEnabled to 0 (default).

  .PARAMETER Enabled
    True enables MAC randomization on all Wi-Fi adapters;
    false resets to default (randomization disabled).

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

  $wlanSvcPath = 'HKLM:\SOFTWARE\Microsoft\WlanSvc\Interfaces'
  if (-not (Test-Path -Path $wlanSvcPath)) {
    Write-Output "$($PSStyle.Formatting.Warning)WlanSvc registry path not found; skipping Wi-Fi MAC randomization.$($PSStyle.Reset)"
    return
  }

  # check-suppress:suppression_doc: probe — WlanSvc path may have no child items; empty result handled downstream.
  $interfaceGuids = Get-ChildItem -Path $wlanSvcPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName
  if ($null -eq $interfaceGuids -or $interfaceGuids.Count -eq 0) {
    Write-Output "$($PSStyle.Formatting.Warning)No WlanSvc interfaces found; skipping Wi-Fi MAC randomization.$($PSStyle.Reset)"
    return
  }

  $targetValue = if ($Enabled) { 1 } else { 0 }
  $actionLabel = if ($Enabled) { 'enabling' } else { 'disabling' }
  $foundWiFiAdapter = $false

  foreach ($guid in $interfaceGuids) {
    $ifacePath = Join-Path -Path $wlanSvcPath -ChildPath $guid
    # check-suppress:suppression_doc: probe whether registry values exist; Get-ItemProperty throws when value is absent.
    $ifaceName = (Get-ItemProperty -Path $ifacePath -Name 'InterfaceName' -ErrorAction SilentlyContinue).InterfaceName
    # check-suppress:suppression_doc: probe whether registry values exist; Get-ItemProperty throws when value is absent.
    $ifaceDesc = (Get-ItemProperty -Path $ifacePath -Name 'InterfaceDescription' -ErrorAction SilentlyContinue).InterfaceDescription

    # Only process Wi-Fi adapters (skip Bluetooth, virtual, etc.)
    $isWiFi = ($null -ne $ifaceName -and $ifaceName -like 'Wi-Fi*') -or
              ($null -ne $ifaceDesc -and $ifaceDesc -like '*Wireless*' -and $ifaceDesc -notlike '*Bluetooth*')
    if (-not $isWiFi) {
      continue
    }

    $foundWiFiAdapter = $true
    $paramsPath = Join-Path -Path $ifacePath -ChildPath 'Parameters'

    # Ensure Parameters subkey exists
    if (-not (Test-Path -Path $paramsPath)) {
      # check-suppress:suppression_doc: best-effort — Parameters subkey may already exist.
      $null = New-Item -Path $paramsPath -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -Path $paramsPath)) {
        Write-Warning "Wi-Fi MAC: could not create Parameters subkey for interface $guid ($ifaceName); skipping."
        continue
      }
    }

    try {
      # check-suppress:suppression_doc: probe whether RandomizationEnabled exists; Get-ItemProperty throws when absent.
      $currentValue = (Get-ItemProperty -Path $paramsPath -Name 'RandomizationEnabled' -ErrorAction SilentlyContinue).RandomizationEnabled
    }
    catch {
      $currentValue = $null
    }

    if ($currentValue -eq $targetValue) {
      Write-Output "Wi-Fi MAC randomization on '$ifaceName' ($guid) already $($actionLabel)d."
      continue
    }

    try {
      Set-ItemProperty -Path $paramsPath -Name 'RandomizationEnabled' -Value $targetValue -Type DWord -ErrorAction Stop
      Write-Output "Wi-Fi MAC randomization on '$ifaceName' ($guid): $($actionLabel)d."
    }
    catch {
      Write-Warning "Wi-Fi MAC: failed to set RandomizationEnabled on interface $guid ($ifaceName): $_"
    }
  }

  if (-not $foundWiFiAdapter) {
    Write-Output "$($PSStyle.Formatting.Warning)No Wi-Fi adapters found in WlanSvc registry; skipping Wi-Fi MAC randomization.$($PSStyle.Reset)"
  }
}
