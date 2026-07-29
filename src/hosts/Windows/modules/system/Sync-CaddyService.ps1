<#
.SYNOPSIS
  Converge local HTTPS ingress via Caddy reverse proxy for all managed services.

.DESCRIPTION
  Creates and maintains a host-local Caddy reverse proxy service (nucleus-caddy)
  that serves HTTPS on localhost for all services with HTTPS network endpoints
  defined in services.json, proxying to their HTTP upstreams.

  Virtual hosts are discovered from services.json: each service with both an
  HTTPS endpoint (protocol: "https") and a non-HTTPS endpoint gets a Caddy site
  block binding 127.0.0.1/::1 with tls internal and reverse_proxy to the HTTP
  upstream.

  Source:
  - https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
  - https://caddyserver.com/docs/caddyfile/directives/tls

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This module does not emit exit codes.
#>
function Sync-CaddyService {
  <#
  .SYNOPSIS
    Converges the nucleus-caddy Windows service for local HTTPS ingress.

  .DESCRIPTION
    Ensures the `nucleus-caddy` Windows service exists, runs at boot, and serves
    HTTPS virtual hosts for all services with HTTPS endpoints in services.json.

    The service uses loopback bindings only (127.0.0.1, ::1) and tls internal,
    providing encrypted local access without exposing new remote listeners.

    When disabled, stops and removes the service while leaving upstream services
    untouched.

  .PARAMETER RepoRoot
    Absolute path to the repository root. Required for explicit caller context.

  .PARAMETER Enabled
    Whether Caddy service convergence should be enforced.

  .EXAMPLE
    Sync-CaddyService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

  .EXAMPLE
    Sync-CaddyService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-NucleusService.ps1")

  if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot does not exist: $RepoRoot"
  }

  # check-suppress:suppression_doc: probe whether caddy binary is installed; Get-Command throws when absent.
  $caddyCommand = Get-Command -Name 'caddy.exe' -ErrorAction SilentlyContinue
  if ($null -eq $caddyCommand) {
    # check-suppress:suppression_doc: fallback probe without .exe suffix for non-Windows or WSL scenarios.
    $caddyCommand = Get-Command -Name 'caddy' -ErrorAction SilentlyContinue
  }

  if ($null -eq $caddyCommand) {
    Write-Warning 'caddy-service: caddy binary not found in PATH; skipping Caddy service convergence.'
    return
  }

  $serviceName = 'nucleus-caddy'
  $proxyRoot = Join-Path -Path $env:ProgramData -ChildPath 'nucleus\caddy'
  $logDir = Join-Path -Path $proxyRoot -ChildPath 'log'
  $caddyConfigDir = Join-Path -Path $proxyRoot -ChildPath 'config'
  $caddyDataDir = Join-Path -Path $proxyRoot -ChildPath 'data'
  $caddyfilePath = Join-Path -Path $proxyRoot -ChildPath 'Caddyfile'

  if ($Enabled) {
    New-Item -Path $proxyRoot -ItemType Directory -Force > $null
    New-Item -Path $logDir -ItemType Directory -Force > $null
    New-Item -Path $caddyConfigDir -ItemType Directory -Force > $null
    New-Item -Path $caddyDataDir -ItemType Directory -Force > $null

    # check-suppress:suppression_doc: probe — services.json may not exist yet; $null check handles absence.
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($null -eq $svc) {
      Write-Warning 'caddy-service: failed to read services.json; skipping Caddy service convergence.'
      return
    }

    $caddyAdmin = if ($svc.caddy.network.admin) { $svc.caddy.network.admin } else { @{ host = '127.0.0.1'; port = 2019 } }

    # Discover virtual hosts: services with both an HTTPS endpoint and a non-HTTPS endpoint.
    $virtualHostBlocks = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $svc.PSObject.Properties) {
      $service = $entry.Value
      if ($null -eq $service.network) { continue }

      $httpsEndpoint = $null
      $httpEndpoint = $null

      foreach ($epEntry in $service.network.PSObject.Properties) {
        $ep = $epEntry.Value
        if ($ep.protocol -eq 'https') {
          $httpsEndpoint = $ep
        }
      }

      if ($null -eq $httpsEndpoint) { continue }

      # Find the corresponding non-HTTPS endpoint (first non-HTTPS endpoint found).
      foreach ($epEntry in $service.network.PSObject.Properties) {
        $ep = $epEntry.Value
        if ($ep.protocol -ne 'https') {
          $httpEndpoint = $ep
          break
        }
      }

      if ($null -eq $httpEndpoint) {
        Write-Warning "caddy-service: service '$($entry.Name)' has HTTPS endpoint but no non-HTTPS endpoint; skipping."
        continue
      }

      $virtualHostBlocks.Add(@"
https://$($httpsEndpoint.host):$($httpsEndpoint.port) {
  bind 127.0.0.1 ::1
  tls internal
  reverse_proxy $($httpEndpoint.host):$($httpEndpoint.port)
}
"@)
    }

    if ($virtualHostBlocks.Count -eq 0) {
      Write-Warning 'caddy-service: no HTTPS virtual hosts discovered; Caddy service would have no sites.'
    }

    $caddyfile = @"
{
  admin $($caddyAdmin.host):$($caddyAdmin.port)
  auto_https disable_redirects
}

$($virtualHostBlocks -join "`n")
"@
    [System.IO.File]::WriteAllText($caddyfilePath, $caddyfile, [System.Text.UTF8Encoding]::new($false))

    $serviceCommand = "`"$($caddyCommand.Source)`" run --config `"$caddyfilePath`" --adapter caddyfile"

    Set-NucleusService -Name $serviceName -BinaryPath $serviceCommand -DisplayName "nucleus Caddy HTTPS proxy" -Description "Managed local Caddy TLS ingress for all configured service HTTPS endpoints"
    Write-Output "caddy-service: ensured HTTPS proxy service ($serviceName)."
    return
  }

  Remove-NucleusService -Name $serviceName
}
