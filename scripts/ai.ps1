<#
.SYNOPSIS
  Unified AI management for Windows.

.DESCRIPTION
  Provides a uniform CLI for AI model management, service status,
  endpoint inspection, and configuration display.

  Subcommands:
    sync       Sync Ollama models with declarative manifest.
    list       List AI models by profile.
    status     Show AI service and model sync status.
    endpoint   Show AI service endpoints (ollama, litellm).
    config     Show effective AI configuration.

  Data sources:
    - src/modules/ai/models.json  — model manifest
    - src/modules/services.json    — service definitions (ollama + litellm)

.PARAMETER Action
  The operation to perform: sync, list, status, endpoint, config.

.PARAMETER DryRun
  Print planned actions without executing pulls or removals (sync only).

.PARAMETER GcOnly
  Skip model pulls; only remove locally installed models absent from the manifest (sync only).

.PARAMETER Profile
  Profile name to filter by (list only).

.PARAMETER Json
  Output machine-readable JSON instead of formatted text.

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\ai.ps1 sync
  .\ai.ps1 list
  .\ai.ps1 list -Profile MacBook
  .\ai.ps1 list -Json
  .\ai.ps1 status
  .\ai.ps1 status -Json
  .\ai.ps1 endpoint
  .\ai.ps1 config
  .\ai.ps1 sync -DryRun

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT, NUCLEUS_AI_SYNC_TIMEOUT, NUCLEUS_AI_SYNC_PROFILE.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('sync', 'list', 'status', 'endpoint', 'config')]
  [string]$Action,

  [switch]$DryRun,
  [switch]$GcOnly,
  [string]$AiProfile,
  [switch]$Json,
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Used inside functions below via closure (PSSA cannot track)
$null = $DryRun, $GcOnly, $AiProfile, $Json

$fmtModulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $fmtModulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (sync, list, status, endpoint, config)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ModelsJson = Join-Path $RepoRoot "src\modules\ai\models.json"
$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"

# ---------------------------------------------------------------------------
# Sync subcommand
# ---------------------------------------------------------------------------

function Invoke-AiSync {
  $modulePath = Join-Path $RepoRoot "src\hosts\Windows\modules\system\Invoke-AISync.ps1"

  if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "ai: sync module not found at '$modulePath'."
  }

  . $modulePath

  Invoke-AISync -RepoRoot $RepoRoot -DryRun:$DryRun -GcOnly:$GcOnly -ServerReadyTimeoutSeconds $(if ($env:NUCLEUS_AI_SYNC_TIMEOUT) { [int]$env:NUCLEUS_AI_SYNC_TIMEOUT } else { 60 })
}

# ---------------------------------------------------------------------------
# List subcommand
# ---------------------------------------------------------------------------

function Invoke-AiList {
  if (-not (Test-Path -LiteralPath $ModelsJson)) {
    throw "ai: models.json not found at $ModelsJson"
  }

  $manifest = Get-Content -Raw -Path $ModelsJson | ConvertFrom-Json
  $allModels = $manifest.models

  if ($AiProfile) {
    if (-not ($allModels.PSObject.Properties.Name -contains $AiProfile)) {
      Write-NucleusError "profile '$AiProfile' not found in models.json"
      exit 1
    }
    $filtered = [ordered]@{}
    $filtered[$AiProfile] = $allModels.$AiProfile
    $allModels = $filtered
  }

  if ($Json) {
    return ($allModels | ConvertTo-Json -Compress)
  }

  # Tabular output: Profile<tab>Model1, Model2, ...
  foreach ($profile in ($allModels.PSObject.Properties.Name | Sort-Object)) {
    $models = @($allModels.$profile) -join ', '
    Write-Output ("{0,-12} {1}" -f $profile, $models)
  }
}

# ---------------------------------------------------------------------------
# Status subcommand
# ---------------------------------------------------------------------------

function Invoke-AiStatus {
  # Check ollama binary availability
  $ollamaCmd = Get-Command "ollama" -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe — expected on fresh systems
  $ollamaAvailable = $null -ne $ollamaCmd

  # Check ollama service
  try {
    $ollamaService = Get-Service -Name "ollama" -ErrorAction Stop
  } catch {
    $ollamaService = $null
  }

  # Check litellm service
  try {
    $litellmService = Get-Service -Name "nucleus-litellm" -ErrorAction Stop
  } catch {
    $litellmService = $null
  }

  # Read manifest
  $desiredCount = 0
  $profileName = "Windows"
  if (Test-Path -LiteralPath $ModelsJson) {
    $manifest = Get-Content -Raw -Path $ModelsJson | ConvertFrom-Json
    $profileName = if ($env:NUCLEUS_AI_SYNC_PROFILE) { $env:NUCLEUS_AI_SYNC_PROFILE } else { "Windows" }
    if ($manifest.models.PSObject.Properties.Name -contains $profileName) {
      $desiredCount = @($manifest.models.$profileName).Count
    }
  }

  # Get installed models via ollama list
  $installedCount = 0
  if ($ollamaAvailable) {
    $listOutput = @(& $ollamaCmd.Source list 2>&1 | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -ne '' })
    $installedCount = $listOutput.Count
  }

  $result = [ordered]@{
    ollama = @{
      available = $ollamaAvailable
      service   = if ($ollamaService) { $ollamaService.Status.ToString().ToLower() } else { 'not-found' }
    }
    litellm = @{
      service = if ($litellmService) { $litellmService.Status.ToString().ToLower() } else { 'not-found' }
    }
    models = @{
      profile    = $profileName
      desired    = $desiredCount
      installed  = $installedCount
    }
  }

  if ($Json) {
    return ($result | ConvertTo-Json -Compress)
  }

  # Human-readable output
  Write-Output "Ollama binary: $(if ($ollamaAvailable) { 'found' } else { 'not found' })"
  if ($ollamaService) {
    Write-Output "Ollama service: $($ollamaService.Status)"
  } else {
    Write-Output "Ollama service: not found"
  }
  if ($litellmService) {
    Write-Output "LiteLLM service: $($litellmService.Status)"
  } else {
    Write-Output "LiteLLM service: not found"
  }
  Write-Output "Model profile: $profileName"
  Write-Output "Desired models: $desiredCount"
  Write-Output "Installed models: $installedCount"
}

# ---------------------------------------------------------------------------
# Endpoint subcommand
# ---------------------------------------------------------------------------

function Invoke-AiEndpoint {
  if (-not (Test-Path -LiteralPath $ServicesJson)) {
    throw "ai: services.json not found at $ServicesJson"
  }

  $services = Get-Content -Raw -Path $ServicesJson | ConvertFrom-Json

  $result = [ordered]@{}

  if ($services.ollama.PSObject.Properties.Name -contains 'network') {
    $result.ollama = $services.ollama.network
  }
  if ($services.litellm.PSObject.Properties.Name -contains 'network') {
    $result.litellm = $services.litellm.network
  }

  if ($Json) {
    return ($result | ConvertTo-Json -Compress)
  }

  # Tabular output: service/endpoint<tab>protocol://host:port
  foreach ($svcName in $result.Keys) {
    $network = $result[$svcName]
    foreach ($epName in ($network.PSObject.Properties.Name | Sort-Object)) {
      $ep = $network.$epName
      Write-Output ("$svcName/$epName`t$($ep.protocol)://$($ep.host):$($ep.port)")
    }
  }
}

# ---------------------------------------------------------------------------
# Config subcommand
# ---------------------------------------------------------------------------

function Invoke-AiConfig {
  # Read models.json
  $profiles = [ordered]@{}
  if (Test-Path -LiteralPath $ModelsJson) {
    $manifest = Get-Content -Raw -Path $ModelsJson | ConvertFrom-Json
    $profiles = $manifest.models
  }

  # Read services.json for endpoints
  $ollamaEndpoint = $null
  $litellmEndpoint = $null
  if (Test-Path -LiteralPath $ServicesJson) {
    $services = Get-Content -Raw -Path $ServicesJson | ConvertFrom-Json
    if ($services.ollama.PSObject.Properties.Name -contains 'network' -and
        $services.ollama.network.PSObject.Properties.Name -contains 'default') {
      $ep = $services.ollama.network.default
      $ollamaEndpoint = "$($ep.protocol)://$($ep.host):$($ep.port)"
    }
    if ($services.litellm.PSObject.Properties.Name -contains 'network' -and
        $services.litellm.network.PSObject.Properties.Name -contains 'default') {
      $ep = $services.litellm.network.default
      $litellmEndpoint = "$($ep.protocol)://$($ep.host):$($ep.port)"
    }
  }

  # Get active profile
  $activeProfile = if ($env:NUCLEUS_AI_SYNC_PROFILE) { $env:NUCLEUS_AI_SYNC_PROFILE } else { "Windows" }

  # Model counts per profile
  $modelCounts = [ordered]@{}
  foreach ($profile in ($profiles.PSObject.Properties.Name | Sort-Object)) {
    $modelCounts[$profile] = @($profiles.$profile).Count
  }

  # Environment variables
  $envVars = [ordered]@{
    OLLAMA_HOST              = $env:OLLAMA_HOST
    NUCLEUS_AI_SYNC_PROFILE  = $env:NUCLEUS_AI_SYNC_PROFILE
    NUCLEUS_AI_SYNC_TIMEOUT  = $env:NUCLEUS_AI_SYNC_TIMEOUT
  }

  $result = [ordered]@{
    profile     = $activeProfile
    modelCounts = $modelCounts
    endpoints   = [ordered]@{
      ollama  = $ollamaEndpoint
      litellm = $litellmEndpoint
    }
    envVars     = $envVars
  }

  if ($Json) {
    return ($result | ConvertTo-Json -Depth 3 -Compress)
  }

  # Human-readable output
  Write-Output "Active profile: $activeProfile"
  Write-Output ""
  Write-Output "Model counts:"
  foreach ($profile in $modelCounts.Keys) {
    Write-Output ("  {0,-12} {1}" -f $profile, $modelCounts[$profile])
  }
  Write-Output ""
  Write-Output "Endpoints:"
  Write-Output "  ollama:  $ollamaEndpoint"
  Write-Output "  litellm: $litellmEndpoint"
  Write-Output ""
  Write-Output "Environment variables:"
  foreach ($var in $envVars.Keys) {
    $val = $envVars[$var]
    if ($val) {
      Write-Output ("  {0,-30} {1}" -f $var, $val)
    } else {
      Write-Output ("  {0,-30} (not set)" -f $var)
    }
  }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Action) {
  'sync'     { Invoke-AiSync }
  'list'     { Invoke-AiList }
  'status'   { Invoke-AiStatus }
  'endpoint' { Invoke-AiEndpoint }
  'config'   { Invoke-AiConfig }
}
