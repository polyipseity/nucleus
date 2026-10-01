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
  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Get-LiteLLMKeySpec.ps1")

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

  # Materialise the AI API keys from src/secrets/system.yml into
  # %ProgramData%\nucleus\secrets\ so the SYSTEM-native service can read them
  # at startup.
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

  # uv tool install places litellm in ~\.local\bin by default.
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

  $programDataDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\litellm"
  $logDir = Get-NucleusSystemLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "litellm"
  $secretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
  $null = New-Item -Path $secretsDir -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Symlink the config so source edits take effect on service restart.
  $configLink = Join-Path -Path $programDataDir -ChildPath "litellm-config.yml"
  $configSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\litellm\config.yml"
  if (-not (Test-Path -Path $configSource -PathType Leaf)) {
    throw "litellm config source not found: $configSource"
  }
  if (Test-Path -Path $configLink) { Remove-Item -Path $configLink -Force }
  New-Item -Path $configLink -ItemType SymbolicLink -Target $configSource -Force > $null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $configLink

  # litellm's get_instance_fn resolves the handler relative to the config
  # directory, so the link has to sit next to the config.
  $handlerLink = Join-Path -Path $programDataDir -ChildPath "cline_handler.py"
  $handlerSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\configs\litellm\cline_handler.py"
  if (-not (Test-Path -Path $handlerSource -PathType Leaf)) {
    throw "Cline handler source not found: $handlerSource"
  }
  if (Test-Path -Path $handlerLink) { Remove-Item -Path $handlerLink -Force }
  New-Item -Path $handlerLink -ItemType SymbolicLink -Target $handlerSource -Force > $null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $handlerLink

  # WHY: the pair, not a merged file. logging.capture selects which streams are captured,
  # never the destination shape (house default: stdout.log + stderr.log).
  $stdoutLogFile = Join-Path -Path $serviceLogDir -ChildPath "stdout.log"
  $stderrLogFile = Join-Path -Path $serviceLogDir -ChildPath "stderr.log"

  # Read the catalog from the repo rather than a runtime copy, which is the same
  # filter envLib.mkSecretArgsForConsumer applies on POSIX.
  $envSecretsCatalog = Join-Path -Path $RepoRoot -ChildPath 'src\modules\env\env-secrets.json'
  $liteLLMKeys = Get-LiteLLMKeySpec -CatalogPath $envSecretsCatalog

  # WHY: a bare name, not a path. LiteLLM-run.ps1 joins $spec.file onto its own
  # $secretsDir, and Join-Path does not treat an absolute child as absolute, so a
  # full key-file path here would match nothing.
  $keySpecs = @()
  foreach ($entry in $liteLLMKeys) {
    $keySpecs += [PSCustomObject]@{ file = $entry.name; env = $entry.envVar }
  }

  $litellmEndpoint = & {
    # check-suppress:suppression_doc: probe -- services.json may not exist yet; $null check handles absence.
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($svc.litellm.network.default) { $svc.litellm.network.default } else { @{ host = '127.0.0.1'; port = 4000 } }
  }

  # A wrapper file avoids the nested quoting that embedding this logic in the
  # sc.exe binPath would create.
  $wrapperScript = Join-Path -Path $programDataDir -ChildPath "run-litellm.ps1"
  $wrapperContent = Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\LiteLLM-run.ps1")
  $keySpecsJson = $keySpecs | ConvertTo-Json -Compress
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
