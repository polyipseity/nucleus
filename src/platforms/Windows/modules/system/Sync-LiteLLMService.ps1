<#
.SYNOPSIS
  Converge the nucleus-litellm Windows native SCM service.

.DESCRIPTION
  Creates and maintains the `nucleus-litellm` native Windows SCM service
  that starts the LiteLLM AI gateway proxy at boot as SYSTEM.

  The wrapper script under %ProgramData%\nucleus\litellm\ reads API keys from
  %ProgramData%\nucleus\secrets\ and the litellm config from a symlink.
  Secrets are materialised from system.yml via SOPS decryption.

  On disable the function removes the SCM service.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    0 on success; 1 on error.
#>

function Sync-LiteLLMService {
  <#
  .SYNOPSIS
    Converges the litellm native SCM service.

  .PARAMETER RepoRoot
    Absolute path to the repository root.  Required so the function can locate
    the litellm config source file under src\modules\configs\litellm\.

  .PARAMETER Enabled
    Whether the litellm service should exist.  When false, the managed service
    is removed if present.

  .PARAMETER GpgExe
    Path to the GPG executable for SOPS decryption.

  .PARAMETER HostKeyPath
    Path to the machine SSH host key for SOPS decryption.

  .PARAMETER SopsExe
    Path to the SOPS executable for secret decryption.

  .PARAMETER PrimarySshKeyPath
    Optional path to the primary SSH key for SOPS decryption.

  .PARAMETER SecretsDir
    Path to the src/secrets directory containing system.yml.

  .EXAMPLE
    Sync-LiteLLMService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true -GpgExe 'C:\...\gpg.exe' -HostKeyPath 'C:\...\ssh_host_ed25519_key' -SopsExe 'C:\...\sops.exe' -SecretsDir 'C:\...\secrets'

  .EXAMPLE
    Sync-LiteLLMService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false -GpgExe 'C:\...\gpg.exe' -HostKeyPath 'C:\...\ssh_host_ed25519_key' -SopsExe 'C:\...\sops.exe' -SecretsDir 'C:\...\secrets'
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$GpgExe,

    [Parameter(Mandatory)]
    [string]$HostKeyPath,

    [Parameter(Mandatory)]
    [string]$SopsExe,

    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory)]
    [string]$SecretsDir
  )

  if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot does not exist: $RepoRoot"
  }

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-NucleusService.ps1")

  $ErrorActionPreference = "Stop"
  $serviceName = 'nucleus-litellm'

  if (-not $Enabled) {
    # check-suppress:suppression_doc: probe whether service exists; Get-Service throws when absent.
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $existingService) {
      Remove-NucleusService -Name $serviceName
      Write-NucleusInfo -CommandName 'litellm' "removed SCM service '$serviceName' (disabled)"
    }
    return
  }

  # Materialise system-level secrets (AI API keys) from src/secrets/system.yml
  # into %ProgramData%\nucleus\secrets\ so the SYSTEM-native litellm SCM service
  # can read them at startup.
  $systemSecretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -Path $systemSecretsDir -ItemType Directory -Force
  $systemYmlPath = Join-Path -Path $SecretsDir -ChildPath "system.yml"
  if (Test-Path -Path $systemYmlPath -PathType Leaf) {
    $getSystemSecretParams = @{
      FilePath    = $systemYmlPath
      GpgExe      = $GpgExe
      HostKeyPath = $HostKeyPath
      RepoRoot    = $RepoRoot
      SopsExe     = $SopsExe
    }
    if (-not [string]::IsNullOrWhiteSpace($PrimarySshKeyPath)) {
      $getSystemSecretParams['PrimarySshKeyPath'] = $PrimarySshKeyPath
    }
    $systemSecrets = Get-Secret @getSystemSecretParams
    foreach ($prop in $systemSecrets.PSObject.Properties) {
      if ($prop.Name -match '^env_' -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
        $keyFile = Join-Path -Path $systemSecretsDir -ChildPath $prop.Name
        $existing = if (Test-Path -Path $keyFile -PathType Leaf) { Get-Content -Path $keyFile -Raw -Encoding UTF8 } else { $null }
        if ($existing -ne $prop.Value) {
          [System.IO.File]::WriteAllText($keyFile, $prop.Value, [System.Text.UTF8Encoding]::new($false))
        }
      }
    }
  }

  # Copy static env-catalog.json to %LOCALAPPDATA%\nucleus\ for wrapper script consumption.
  $catalogSource = Join-Path -Path $RepoRoot -ChildPath 'src\hosts\Windows\env-catalog.json'
  $catalogPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus\env-catalog.json'
  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  $null = New-Item -Path (Split-Path $catalogPath) -ItemType Directory -Force
  Copy-Item -Path $catalogSource -Destination $catalogPath -Force

  # Find the litellm binary installed by uv.
  # uv tool install places binaries in ~\.local\bin by default.
  $litellmBin = Join-Path -Path $HOME -ChildPath ".local\bin\litellm.exe"
  if (-not (Test-Path -Path $litellmBin -PathType Leaf)) {
    # check-suppress:suppression_doc: probe whether the binary is on PATH; Get-Command throws when absent.
    $litellmCmd = Get-Command -Name "litellm" -ErrorAction SilentlyContinue
    if ($null -eq $litellmCmd) {
      Write-NucleusInfo -CommandName 'litellm' "binary not found; ensure Invoke-UvSetup has installed 'litellm[proxy]'"
      return
    }
    $litellmBin = $litellmCmd.Source
  }

  # Prepare ProgramData directories.
  $programDataDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\litellm"
  $logDir = Get-NucleusSystemLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "litellm"
  $secretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
  $null = New-Item -Path $secretsDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Symlink the config so source edits take effect on service restart without
  # re-running apply.
  $configLink = Join-Path -Path $programDataDir -ChildPath "litellm-config.yml"
  $configSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\litellm\config.yml"
  if (-not (Test-Path -Path $configSource -PathType Leaf)) {
    throw "litellm config source not found: $configSource"
  }
  if (Test-Path -Path $configLink) { Remove-Item -Path $configLink -Force }
  New-Item -Path $configLink -ItemType SymbolicLink -Target $configSource -Force > $null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $configLink

  # Symlink the Cline custom handler alongside the config.  litellm's
  # get_instance_fn resolves the handler relative to the config file directory.
  $handlerLink = Join-Path -Path $programDataDir -ChildPath "cline_handler.py"
  $handlerSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\litellm\cline_handler.py"
  if (-not (Test-Path -Path $handlerSource -PathType Leaf)) {
    throw "Cline handler source not found: $handlerSource"
  }
  if (Test-Path -Path $handlerLink) { Remove-Item -Path $handlerLink -Force }
  New-Item -Path $handlerLink -ItemType SymbolicLink -Target $handlerSource -Force > $null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $handlerLink

  # Symlink the cooldown-400 callback alongside the config.
  $cooldownLink = Join-Path -Path $programDataDir -ChildPath "litellm-cooldown-400.py"
  $cooldownSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\litellm\cooldown_400.py"
  if (-not (Test-Path -Path $cooldownSource -PathType Leaf)) {
    throw "Cooldown-400 callback source not found: $cooldownSource"
  }
  if (Test-Path -Path $cooldownLink) { Remove-Item -Path $cooldownLink -Force }
  New-Item -Path $cooldownLink -ItemType SymbolicLink -Target $cooldownSource -Force > $null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $cooldownLink

  # WHY: the pair, not a merged file. logging.capture selects which streams are captured,
  # never the destination shape (house default: stdout.log + stderr.log).
  $stdoutLogFile = Join-Path -Path $serviceLogDir -ChildPath "stdout.log"
  $stderrLogFile = Join-Path -Path $serviceLogDir -ChildPath "stderr.log"

  # Data-driven: read the env catalog to discover API keys and their env var
  # mappings.  The catalog is generated by apply.ps1 to the runtime config
  # directory.
  $catalogPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus\env-catalog.json'
  $catalog = if (Test-Path -LiteralPath $catalogPath) {
    Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
  } else { [PSCustomObject]@{ keys = @() } }

  # Build JSON key-spec array for the wrapper script: [{file, env}, ...]
  $keySpecs = @()
  foreach ($entry in $catalog.keys) {
    $keySpecs += [PSCustomObject]@{ file = $entry.name; env = $entry.envVar }
  }

  $litellmEndpoint = & {
    # check-suppress:suppression_doc: probe -- services.json may not exist yet; $null check handles absence.
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($svc.litellm.network.default) { $svc.litellm.network.default } else { @{ host = '127.0.0.1'; port = 4000 } }
  }

  # Write a PowerShell wrapper script that sets environment variables then
  # launches litellm.  Using a wrapper file avoids the nested-quoting problem
  # that would arise from embedding this logic inline in sc.exe binPath.
  $wrapperScript = Join-Path -Path $programDataDir -ChildPath "run-litellm.ps1"
  $wrapperContent = Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\LiteLLM-run.ps1")
  $keySpecsJson = $keySpecs | ConvertTo-Json -Compress
  # Redis env vars for LiteLLM coordination + response cache.
  $redisConfig = & {
    # check-suppress:suppression_doc: probe -- services.json may not exist yet; $null check handles absence.
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($svc.redis.network.default) { $svc.redis.network.default } else { @{ host = '127.0.0.1'; port = 6379 } }
  }
  $redisHost = $redisConfig.host
  $redisPort = [string]$redisConfig.port
  $wrapperContent = $wrapperContent `
    -replace '__LITELLM_BIN__', $litellmBin `
    -replace '__CONFIG_LINK__', $configLink `
    -replace '__STDOUT_LOG__', $stdoutLogFile `
    -replace '__STDERR_LOG__', $stderrLogFile `
    -replace '__HOST__', $($litellmEndpoint.host) `
    -replace '__PORT__', $($litellmEndpoint.port) `
    -replace "'__KEY_SPECS__'", $keySpecsJson `
    -replace "'__REDIS_HOST__'", $redisHost `
    -replace "'__REDIS_PORT__'", $redisPort
  [System.IO.File]::WriteAllText($wrapperScript, $wrapperContent, [System.Text.UTF8Encoding]::new($false))

  # check-suppress:suppression_doc: probe whether service already exists; Get-Service throws when absent.
  $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($null -eq $existingService) {
    Set-NucleusService -Name $serviceName -BinaryPath "pwsh.exe -NoLogo -ExecutionPolicy Bypass -File `"$wrapperScript`"" -DisplayName "nucleus LiteLLM AI gateway proxy" -Description "Managed LiteLLM proxy for unified AI model access (http://$($litellmEndpoint.host):$($litellmEndpoint.port))"
    Write-NucleusInfo -CommandName 'litellm' "created SCM service '$serviceName'"
  }
  else {
    Set-NucleusService -Name $serviceName -BinaryPath "pwsh.exe -NoLogo -ExecutionPolicy Bypass -File `"$wrapperScript`"" -DisplayName "nucleus LiteLLM AI gateway proxy" -Description "Managed LiteLLM proxy for unified AI model access (http://$($litellmEndpoint.host):$($litellmEndpoint.port))"
    Write-NucleusInfo -CommandName 'litellm' "updated SCM service '$serviceName'"
  }

  Write-NucleusInfo -CommandName 'litellm' 'ensured SCM service on http://127.0.0.1:4000'
}
