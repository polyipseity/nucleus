#
.SYNOPSIS
  Converge the nucleus-redis Windows native SCM service.

.DESCRIPTION
  Creates and maintains the `nucleus-redis` native Windows SCM service that
  starts a local Redis server at boot as SYSTEM, bound to loopback for LiteLLM
  coordination and response caching.

  Redis is installed via WinGet (tporadowski.redis) when not already present.
  The server is configured with requirepass from the SOPS-decrypted
  env_redis_password secret (materialised by apply.ps1 into
  %ProgramData%\nucleus\secrets\env_redis_password), matching the POSIX
  REDIS_PASSWORD pipeline.

  On disable the function removes the SCM service.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    0 on success; 1 on error.
#

function Sync-RedisService {
  <#
  .SYNOPSIS
    Converges the redis native SCM service.

  .PARAMETER RepoRoot
    Absolute path to the repository root.  Required so the function can locate
    services.json for the redis network endpoint.

  .PARAMETER Enabled
    Whether the redis service should exist.  When false, the managed service
    is removed if present.

  .EXAMPLE
    Sync-RedisService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

  .EXAMPLE
    Sync-RedisService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false
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

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-NucleusService.ps1")

  $ErrorActionPreference = "Stop"
  $serviceName = 'nucleus-redis'

  if (-not $Enabled) {
    # check-suppress:suppression_doc: probe whether service exists; Get-Service throws when absent.
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $existingService) {
      Remove-NucleusService -Name $serviceName
      Write-NucleusInfo -CommandName 'redis' "removed SCM service '$serviceName' (disabled)"
    }
    return
  }

  # Data-driven: read the redis network endpoint from services.json.
  $redisConfig = & {
    # check-suppress:suppression_doc: probe -- services.json may not exist yet; $null check handles absence.
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($svc.redis.network.default) { $svc.redis.network.default } else { @{ host = '127.0.0.1'; port = 6379 } }
  }
  $redisHost = $redisConfig.host
  $redisPort = [string]$redisConfig.port

  # Locate the redis-server binary. Prefer the WinGet-installed binary on PATH;
  # fall back to the well-known install location.
  $redisServer = $null
  # check-suppress:suppression_doc: probe whether redis-server is on PATH; Get-Command throws when absent.
  $redisCmd = Get-Command -Name "redis-server" -ErrorAction SilentlyContinue
  if ($null -ne $redisCmd) {
    $redisServer = $redisCmd.Source
  }
  else {
    $candidate = Join-Path -Path $env:ProgramFiles -ChildPath "Redis\redis-server.exe"
    if (Test-Path -Path $candidate -PathType Leaf) {
      $redisServer = $candidate
    }
  }

  if ($null -eq $redisServer) {
    # Install Redis via WinGet when absent. The version is pinned in
    # src/lockfiles/lockfile.json (winget section) — bump-lockfile is the only
    # authorized version changer.
    Write-NucleusInfo -CommandName 'redis' "redis-server not found; installing via WinGet (tporadowski.redis)"
    # check-suppress:suppression_doc: probe whether winget is available; throws when absent.
    $wingetCmd = Get-Command -Name "winget" -ErrorAction SilentlyContinue
    if ($null -eq $wingetCmd) {
      throw "winget not found; cannot install Redis. Install tporadowski.redis manually or run the package DSC step first."
    }
    & winget.exe install --exact --id tporadowski.redis --source winget --accept-package-agreements --accept-source-agreements > $null
    # Re-probe after install.
    $redisCmd = Get-Command -Name "redis-server" -ErrorAction SilentlyContinue
    if ($null -ne $redisCmd) {
      $redisServer = $redisCmd.Source
    }
    else {
      $candidate = Join-Path -Path $env:ProgramFiles -ChildPath "Redis\redis-server.exe"
      if (Test-Path -Path $candidate -PathType Leaf) {
        $redisServer = $candidate
      }
    }
    if ($null -eq $redisServer) {
      throw "redis-server still not found after WinGet install; check the install log."
    }
  }

  # Prepare ProgramData directories.
  $programDataDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\redis"
  $logDir = Get-NucleusSystemLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "redis"
  $secretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
  $null = New-Item -Path $programDataDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -Path $serviceLogDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  # Read the SOPS-decrypted requirepass secret (materialised by apply.ps1).
  $passwordFile = Join-Path -Path $secretsDir -ChildPath "env_redis_password"
  $requirePass = $null
  if (Test-Path -Path $passwordFile -PathType Leaf) {
    $requirePass = (Get-Content -Path $passwordFile -Raw -Encoding UTF8).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($requirePass)) {
    throw "Redis requirepass secret not found at $passwordFile; ensure apply.ps1 has materialised system.yml secrets."
  }

  # Write a redis.conf so the server binds loopback, requires the SOPS
  # password, and evicts volatile keys LRU (matching the NixOS nucleus-redis
  # server). Using a config file avoids nested-quoting problems in sc.exe
  # binPath and lets source edits take effect on restart.
  $redisConf = Join-Path -Path $programDataDir -ChildPath "redis.conf"
  $confLines = @(
    "# Managed by nucleus Sync-RedisService. Do not edit by hand."
    "bind $redisHost"
    "port $redisPort"
    "requirepass $requirePass"
    "maxmemory-policy volatile-lru"
    "save ''"
    "appendonly no"
    "logfile `"$serviceLogDir\redis.log`""
  )
  [System.IO.File]::WriteAllText($redisConf, ($confLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

  # check-suppress:suppression_doc: probe whether service already exists; Get-Service throws when absent.
  $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($null -eq $existingService) {
    Set-NucleusService -Name $serviceName -BinaryPath "`"$redisServer`" `"$redisConf`"" -DisplayName "nucleus Redis in-memory data store" -Description "Managed Redis for LiteLLM coordination and response cache (http://$($redisHost):$($redisPort))"
    Write-NucleusInfo -CommandName 'redis' "created SCM service '$serviceName'"
  }
  else {
    Set-NucleusService -Name $serviceName -BinaryPath "`"$redisServer`" `"$redisConf`"" -DisplayName "nucleus Redis in-memory data store" -Description "Managed Redis for LiteLLM coordination and response cache (http://$($redisHost):$($redisPort))"
    Write-NucleusInfo -CommandName 'redis' "updated SCM service '$serviceName'"
  }

  Write-NucleusInfo -CommandName 'redis' "ensured SCM service on $redisHost`:$redisPort"
}
