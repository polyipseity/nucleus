# Sync-JellyfinHttpsProxy.ps1 — Converge local HTTPS ingress for Jellyfin.
#
# Creates and maintains a host-local Caddy reverse proxy service that serves
# Jellyfin on https://localhost:8920 and proxies to http://127.0.0.1:8096.
# The pattern is reusable for other local services by adding additional Caddy
# site blocks in the same managed config.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/caddy/
# - https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
# - https://caddyserver.com/docs/caddyfile/directives/tls
# - https://caddyserver.com/docs/command-line#caddy-trust

function Sync-JellyfinHttpsProxy {
  <#
  .SYNOPSIS
    Converges a local Caddy HTTPS proxy for Jellyfin.

  .DESCRIPTION
    Ensures the `nucleus-jellyfin-https` Windows service exists, runs at boot,
    and serves `https://localhost:8920` with `tls internal`, reverse-proxying
    to Jellyfin's local HTTP endpoint `127.0.0.1:8096`.

    The service uses loopback bindings only, so this introduces encrypted local
    access without exposing a new remote listener on the LAN.

    When disabled, the function stops and removes the managed service while
    leaving Jellyfin itself untouched.

  .PARAMETER RepoRoot
    Absolute path to the repository root. Required for explicit caller context.

  .PARAMETER Enabled
    Whether HTTPS proxy convergence should be enforced.

  .EXAMPLE
    Sync-JellyfinHttpsProxy -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

  .EXAMPLE
    Sync-JellyfinHttpsProxy -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot does not exist: $RepoRoot"
  }

  $caddyCommand = Get-Command -Name 'caddy.exe' -ErrorAction SilentlyContinue
  if ($null -eq $caddyCommand) {
    Write-Warning 'jellyfin-https: caddy.exe not found in PATH; skipping HTTPS proxy convergence.'
    return
  }

  $serviceName = 'nucleus-jellyfin-https'
  $proxyRoot = Join-Path -Path $env:ProgramData -ChildPath 'nucleus\jellyfin\https'
  $logDir = Join-Path -Path $proxyRoot -ChildPath 'log'
  $caddyConfigDir = Join-Path -Path $proxyRoot -ChildPath 'config'
  $caddyDataDir = Join-Path -Path $proxyRoot -ChildPath 'data'
  $caddyfilePath = Join-Path -Path $proxyRoot -ChildPath 'Caddyfile'

  if ($Enabled) {
    New-Item -Path $proxyRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    New-Item -Path $caddyConfigDir -ItemType Directory -Force | Out-Null
    New-Item -Path $caddyDataDir -ItemType Directory -Force | Out-Null

    $caddyfile = @'
{
  admin 127.0.0.1:2019
}

:8920 {
  bind 127.0.0.1 ::1
  tls internal
  reverse_proxy 127.0.0.1:8096
}
'@
    [System.IO.File]::WriteAllText($caddyfilePath, $caddyfile, [System.Text.UTF8Encoding]::new($false))

    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $serviceCommand = "`"$($caddyCommand.Source)`" run --config `"$caddyfilePath`" --adapter caddyfile"

    if ($null -eq $existingService) {
      & sc.exe create $serviceName binPath= $serviceCommand start= auto DisplayName= "nucleus Jellyfin HTTPS proxy" | Out-Null
      & sc.exe description $serviceName "Managed local Caddy TLS ingress for Jellyfin (https://localhost:8920 -> http://127.0.0.1:8096)" | Out-Null
    }
    else {
      if ($existingService.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
      }
      & sc.exe config $serviceName binPath= $serviceCommand start= auto | Out-Null
    }

    Start-Service -Name $serviceName
    Write-Output 'jellyfin-https: ensured HTTPS proxy service on https://localhost:8920.'
    return
  }

  $serviceToRemove = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($null -eq $serviceToRemove) {
    return
  }

  if ($serviceToRemove.Status -ne 'Stopped') {
    Stop-Service -Name $serviceName -Force
  }

  & sc.exe delete $serviceName | Out-Null
}
