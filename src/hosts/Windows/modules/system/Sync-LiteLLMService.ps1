<#
.SYNOPSIS
  Converge the nucleus-litellm Windows native SCM service.

.DESCRIPTION
  Creates and maintains the `nucleus-litellm` native Windows SCM service
  that starts the LiteLLM AI gateway proxy at boot as SYSTEM.  Replaces the
  legacy per-user NucleusLiteLLM scheduled task.

  The wrapper script under %ProgramData%\nucleus\litellm\ reads API keys from
  %ProgramData%\nucleus\secrets\ and the litellm config from a symlink.
  Secrets are materialised by apply.ps1 via SOPS decryption of system.yml.

  On disable the function removes both the SCM service and any stale scheduled
  task.

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
    the litellm config source file under src\modules\ai\.

  .PARAMETER Enabled
    Whether the litellm service should exist.  When false, the managed service
    is removed if present.

  .EXAMPLE
    Sync-LiteLLMService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$true

  .EXAMPLE
    Sync-LiteLLMService -RepoRoot 'C:\Users\admin\nucleus' -Enabled:$false
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
  $serviceName = 'nucleus-litellm'
  $oldTaskName = 'NucleusLiteLLM'

  # Clean up the legacy scheduled task unconditionally so a single apply pass
  # that transitions from schtask→native removes the old task in one go.
  $existingTask = Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
    Write-Output "litellm: removed legacy scheduled task '$oldTaskName'"
  }

  if (-not $Enabled) {
    # WHY: probe whether service exists; Get-Service throws when absent.
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $existingService) {
      Remove-NucleusService -Name $serviceName
      Write-Output "litellm: removed SCM service '$serviceName' (disabled)"
    }
    return
  }

  # Find the litellm binary installed by uv.
  # uv tool install places binaries in ~\.local\bin by default.
  $litellmBin = Join-Path -Path $HOME -ChildPath ".local\bin\litellm.exe"
  if (-not (Test-Path -Path $litellmBin -PathType Leaf)) {
    # WHY: probe whether the binary is on PATH; Get-Command throws when absent.
    $litellmCmd = Get-Command -Name "litellm" -ErrorAction SilentlyContinue
    if ($null -eq $litellmCmd) {
      Write-Output "litellm: binary not found; ensure Invoke-UvSetup has installed 'litellm[proxy]'"
      return
    }
    $litellmBin = $litellmCmd.Source
  }

  # Prepare ProgramData directories.
  $programDataDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\litellm"
  $logDir = Get-NucleusSystemLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "litellm"
  $secretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
  $null = New-Item -Path $secretsDir -ItemType Directory -Force

  . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-ManagedSymlinkDeleteProtection.ps1")

  # Symlink the config so source edits take effect on service restart without
  # re-running apply.
  $configLink = Join-Path -Path $programDataDir -ChildPath "litellm-config.yml"
  $configSource = Join-Path -Path $RepoRoot -ChildPath "src\modules\ai\litellm-config.yml"
  if (-not (Test-Path -Path $configSource -PathType Leaf)) {
    throw "litellm config source not found: $configSource"
  }
  if (Test-Path -Path $configLink) { Remove-Item -Path $configLink -Force }
  New-Item -Path $configLink -ItemType SymbolicLink -Target $configSource -Force | Out-Null
  Set-ManagedSymlinkDeleteProtection -Context "Sync-LiteLLMService" -Path $configLink

  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"
  $openrouterKeyFile = Join-Path -Path $secretsDir -ChildPath "ai_openrouter_api_key"
  $opencodeGoKeyFile = Join-Path -Path $secretsDir -ChildPath "ai_opencode_go_api_key"
  $opencodeZenKeyFile = Join-Path -Path $secretsDir -ChildPath "ai_opencode_zen_api_key"

  # Read the litellm endpoint from the canonical service registry.
  $litellmEndpoint = & {
    $svc = Get-Content -Raw (Join-Path $RepoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($svc.litellm.network.default) { $svc.litellm.network.default } else { @{ host = '127.0.0.1'; port = 4000 } }
  }

  # Write a PowerShell wrapper script that sets environment variables then
  # launches litellm.  Using a wrapper file avoids the nested-quoting problem
  # that would arise from embedding this logic inline in sc.exe binPath.
  $wrapperScript = Join-Path -Path $programDataDir -ChildPath "run-litellm.ps1"
  $wrapperContent = @"
`$env:LITELLM_LOG = 'WARNING'
`$env:OPENROUTER_API_KEY = if (Test-Path '$openrouterKeyFile') { Get-Content '$openrouterKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
`$env:OPENCODE_GO_API_KEY = if (Test-Path '$opencodeGoKeyFile') { Get-Content '$opencodeGoKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
`$env:OPENCODE_ZEN_API_KEY = if (Test-Path '$opencodeZenKeyFile') { Get-Content '$opencodeZenKeyFile' -Raw | ForEach-Object { `$_.Trim() } } else { '' }
& "$litellmBin" --config "$configLink" --port $($litellmEndpoint.port) --host $($litellmEndpoint.host) --drop_params *>> "$logFile"
"@
  [System.IO.File]::WriteAllText($wrapperScript, $wrapperContent, [System.Text.UTF8Encoding]::new($false))

  # WHY: probe whether service already exists; Get-Service throws when absent.
  $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($null -eq $existingService) {
    Set-NucleusService -Name $serviceName -BinaryPath "pwsh.exe -NoLogo -ExecutionPolicy Bypass -File `"$wrapperScript`"" -DisplayName "nucleus LiteLLM AI gateway proxy" -Description "Managed LiteLLM proxy for unified AI model access (http://$($litellmEndpoint.host):$($litellmEndpoint.port))"
    Write-Output "litellm: created SCM service '$serviceName'"
  }
  else {
    Set-NucleusService -Name $serviceName -BinaryPath "pwsh.exe -NoLogo -ExecutionPolicy Bypass -File `"$wrapperScript`"" -DisplayName "nucleus LiteLLM AI gateway proxy" -Description "Managed LiteLLM proxy for unified AI model access (http://$($litellmEndpoint.host):$($litellmEndpoint.port))"
    Write-Output "litellm: updated SCM service '$serviceName'"
  }

  Write-Output "litellm: ensured SCM service on http://127.0.0.1:4000"
}
