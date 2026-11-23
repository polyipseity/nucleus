<#
.SYNOPSIS
  Windows twin of src/scripts/apply.sh: dispatch apply subcommands.

.DESCRIPTION
  Windows-side counterpart to src/scripts/apply.sh. Dispatches the same
  action vocabulary so `nix run .#apply` behaves identically across
  macOS/NixOS and Windows:
    - health-check: pre-flight disk/connectivity/secret checks. Not yet
      implemented for Windows; accepts the POSIX health-check flags and exits 0.
    - audit-store:  Nix store baseline report. Not yet implemented for
      Windows; reports and exits 0.
    - status:       read-only apply history retrieval (no elevation).
    - apply:        full configuration lifecycle. Handled by the Windows
      host orchestrator (src/hosts/Windows/apply.ps1); accepts apply flags for
      CLI parity and exits 0 when invoked here.

.PARAMETER Action
  The operation to perform: health-check, audit-store, status, apply.

.PARAMETER RepoRoot
  Repository root. Auto-derived from the script location when omitted.

.PARAMETER History
  For status: show the N newest records, most recent first.

.PARAMETER Json
  For status: emit {"version":1,"entries":[...]} JSON.

.EXAMPLE
  .\scripts\apply.ps1 health-check --min-free-bytes 8000000000
  .\scripts\apply.ps1 audit-store
  .\scripts\apply.ps1 status
  .\scripts\apply.ps1 status --history 5 --json
  .\scripts\apply.ps1 --no-health-check

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Action = 'apply',

  [string]$RepoRoot = $(if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { '' }),

  [Alias('h')]
  [switch]$Help,

  [switch]$Json,

  [int]$History,

  [Alias('ai-sync')]
  [switch]$AiSync,

  [Alias('no-ai-sync')]
  [switch]$NoAiSync,

  [Alias('replica-sync')]
  [switch]$ReplicaSync,

  [Alias('no-replica-sync')]
  [switch]$NoReplicaSync,

  [Alias('store-audit')]
  [switch]$StoreAudit,

  [Alias('no-store-audit')]
  [switch]$NoStoreAudit,

  [Alias('target-user')]
  [string]$TargetUser,

  [string]$Username,

  [Alias('vm-sync')]
  [switch]$VmSync,

  [Alias('no-vm-sync')]
  [switch]$NoVmSync,

  [Alias('vm-setup')]
  [switch]$VmSetup,

  [Alias('no-vm-setup')]
  [switch]$NoVmSetup,

  [Alias('health-check')]
  [switch]$HealthCheck,

  [Alias('no-health-check')]
  [switch]$NoHealthCheck,

  [Alias('min-free-bytes')]
  [string]$MinFreeBytes,

  [Alias('secret-health')]
  [switch]$SecretHealth,

  [Alias('no-secret-health')]
  [switch]$NoSecretHealth,

  [Alias('log-health')]
  [switch]$LogHealth,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs = @()
)

. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  # scripts/apply.ps1 lives at <repo>/scripts/apply.ps1; repo root is the parent.
  $RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).Path
}

if ($Action -in @('--help', '-h')) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}
if ($Action -match '^--' -or $Action -match '^-[A-Za-z]') {
  $RemainingArgs = @($Action) + $RemainingArgs
  $Action = 'apply'
}
if ($Action -notin @('health-check', 'audit-store', 'status', 'apply')) {
  Write-NucleusError -CommandName apply "unknown action '$Action'"
  exit 1
}

# Parse status flags from remaining args for CLI-style invocations (--history N, --json).
$statusHistorySpecified = $PSBoundParameters.ContainsKey('History')
if ($statusHistorySpecified -and $History -lt 0) {
  Write-NucleusError -CommandName status "status: --history requires a non-negative integer"
  exit 1
}
$statusHistoryCount = if ($statusHistorySpecified) { $History } else { 1 }
$statusJson = $Json.IsPresent
if ($Action -eq 'status' -and $RemainingArgs.Count -gt 0) {
  for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
    $arg = $RemainingArgs[$i]
    if ($arg -eq '--json') {
      $statusJson = $true
    } elseif ($arg -eq '--history') {
      if ($i + 1 -ge $RemainingArgs.Count) {
        Write-NucleusError -CommandName status "status: --history requires a value"
        exit 1
      }
      $i++
      $parsed = 0
      if (-not [int]::TryParse($RemainingArgs[$i], [ref]$parsed) -or $parsed -lt 0) {
        Write-NucleusError -CommandName status "status: --history requires a non-negative integer"
        exit 1
      }
      $statusHistorySpecified = $true
      $statusHistoryCount = $parsed
    } elseif ($arg -like '--history=*') {
      $val = $arg.Substring('--history='.Length)
      $parsed = 0
      if (-not [int]::TryParse($val, [ref]$parsed) -or $parsed -lt 0) {
        Write-NucleusError -CommandName status "status: --history requires a non-negative integer"
        exit 1
      }
      $statusHistorySpecified = $true
      $statusHistoryCount = $parsed
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
      Get-Help $PSCommandPath -Detailed
      exit 0
    } else {
      Write-NucleusError -CommandName status "status: unsupported argument '$arg'"
      exit 1
    }
  }
}

function Invoke-ApplyStatus {
  param(
    [bool]$ExplicitHistory,
    [int]$Count,
    [bool]$AsJson
  )

  $histLib = Join-Path $PSScriptRoot '..\src\scripts\lib\apply-history.ps1'
  if (-not (Test-Path -LiteralPath $histLib)) {
    $histLib = Join-Path $RepoRoot 'src\scripts\lib\apply-history.ps1'
  }
  . $histLib

  try {
    if ($AsJson) {
      $effectiveCount = if ($ExplicitHistory) { $Count } else { 1 }
      $json = Get-ApplyHistoryEntriesJson -Count $effectiveCount
      [Console]::Out.WriteLine($json)
      return 0
    }

    if (-not $ExplicitHistory) {
      $lines = @(Get-ApplyHistoryLatestHuman)
      foreach ($line in $lines) {
        [Console]::Out.WriteLine([string]$line)
      }
      return 0
    }

    $json = Get-ApplyHistoryEntriesJson -Count $Count
    $obj = $json | ConvertFrom-Json -ErrorAction Stop
    $entries = @($obj.entries)
    if ($entries.Count -eq 0) {
      [Console]::Out.WriteLine("No apply history yet.")
      return 0
    }
    $keys = @('result','phase','appliedAt','host','user','repoRoot','commitHash','branch','detachedHead','appliedCommitTag','lastTagOnBranch','hasUnstaged','hasStaged','hasUntracked','isDirty')
    for ($idx = 0; $idx -lt $entries.Count; $idx++) {
      if ($idx -gt 0) { [Console]::Out.WriteLine('') }
      $e = $entries[$idx]
      foreach ($k in $keys) {
        $v = $e.$k
        if ($null -eq $v) {
          [Console]::Out.WriteLine("${k}: null")
        } else {
          [Console]::Out.WriteLine("${k}: $v")
        }
      }
    }
    return 0
  } catch {
    $msg = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$_" }
    Write-NucleusError -CommandName status $msg
    return 1
  }
}

function Get-ApplyFlagParameterMap {
  # Ordered map: param name -> flag string for error reporting.
  return @(
    @{ Name = 'Help'; Flag = '--help'; Kind = 'switch' }
    @{ Name = 'Json'; Flag = '--json'; Kind = 'switch' }
    @{ Name = 'History'; Flag = '--history'; Kind = 'value' }
    @{ Name = 'AiSync'; Flag = '--ai-sync'; Kind = 'switch' }
    @{ Name = 'NoAiSync'; Flag = '--no-ai-sync'; Kind = 'switch' }
    @{ Name = 'ReplicaSync'; Flag = '--replica-sync'; Kind = 'switch' }
    @{ Name = 'NoReplicaSync'; Flag = '--no-replica-sync'; Kind = 'switch' }
    @{ Name = 'StoreAudit'; Flag = '--store-audit'; Kind = 'switch' }
    @{ Name = 'NoStoreAudit'; Flag = '--no-store-audit'; Kind = 'switch' }
    @{ Name = 'TargetUser'; Flag = '--target-user'; Kind = 'value' }
    @{ Name = 'Username'; Flag = '--username'; Kind = 'value' }
    @{ Name = 'VmSync'; Flag = '--vm-sync'; Kind = 'switch' }
    @{ Name = 'NoVmSync'; Flag = '--no-vm-sync'; Kind = 'switch' }
    @{ Name = 'VmSetup'; Flag = '--vm-setup'; Kind = 'switch' }
    @{ Name = 'NoVmSetup'; Flag = '--no-vm-setup'; Kind = 'switch' }
    @{ Name = 'HealthCheck'; Flag = '--health-check'; Kind = 'switch' }
    @{ Name = 'NoHealthCheck'; Flag = '--no-health-check'; Kind = 'switch' }
    @{ Name = 'MinFreeBytes'; Flag = '--min-free-bytes'; Kind = 'value' }
    @{ Name = 'SecretHealth'; Flag = '--secret-health'; Kind = 'switch' }
    @{ Name = 'NoSecretHealth'; Flag = '--no-secret-health'; Kind = 'switch' }
    @{ Name = 'LogHealth'; Flag = '--log-health'; Kind = 'switch' }
  )
}

function Test-ApplyFlagBound {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters
  )
  if ($Kind -eq 'switch') {
    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue # check-suppress:suppression_doc: param variable may not exist as a script-scope variable when not bound; absence means not bound
    return ($null -ne $var -and $var.Value -is [System.Management.Automation.SwitchParameter] -and $var.Value.IsPresent)
  }
  return $BoundParameters.ContainsKey($Name)
}

function Assert-ApplyBoundFlagSet {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [Parameter(Mandatory)][string[]]$AllowedParams,
    [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters
  )
  $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $AllowedParams) {
    $null = $allowed.Add($name) # check-suppress:suppression_doc: HashSet.Add returns bool, intentionally discarded
  }
  foreach ($entry in @(Get-ApplyFlagParameterMap)) {
    if ($allowed.Contains([string]$entry.Name)) { continue }
    if (Test-ApplyFlagBound -Name ([string]$entry.Name) -Kind ([string]$entry.Kind) -BoundParameters $BoundParameters) {
      Write-NucleusError -CommandName $CommandName "${CommandName}: unsupported argument '$($entry.Flag)'"
      exit 1
    }
  }
}

function Get-ApplyRemainingArgList {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [string[]]$ArgList,
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$AllowedValueFlags
  )
  $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($flag in $AllowedValueFlags) {
    $null = $allowed.Add($flag) # check-suppress:suppression_doc: HashSet.Add returns bool, intentionally discarded
  }
  $knownValueFlags = @(
    @(Get-ApplyFlagParameterMap) | Where-Object { $_.Kind -eq 'value' } | ForEach-Object {
      @{ Flag = [string]$_.Flag; Name = [string]$_.Name }
    }
  )
  $remaining = [System.Collections.Generic.List[string]]::new()
  foreach ($arg in @($ArgList)) {
    $consumed = $false
    foreach ($entry in $knownValueFlags) {
      $flag = [string]$entry.Flag
      if ($arg -like "$flag=*") {
        if (-not $allowed.Contains($flag)) {
          Write-NucleusError -CommandName $CommandName "${CommandName}: unsupported argument '$arg'"
          exit 1
        }
        $value = ([string]$arg).Substring($flag.Length + 1)
        Set-Variable -Name ([string]$entry.Name) -Scope Script -Value $value
        $consumed = $true
        break
      }
    }
    if (-not $consumed) {
      $null = $remaining.Add([string]$arg) # check-suppress:suppression_doc: List.Add result intentionally discarded
    }
  }
  return @($remaining.ToArray())
}

switch ($Action) {
  'health-check' {
    Assert-ApplyBoundFlagSet -CommandName health-check -BoundParameters $PSBoundParameters -AllowedParams @(
      'Help', 'MinFreeBytes', 'SecretHealth', 'NoSecretHealth', 'LogHealth', 'StoreAudit', 'NoStoreAudit'
    )
    if ($Help.IsPresent) {
      Get-Help $PSCommandPath -Detailed
      exit 0
    }
    $remainingHealthCheckArgs = @(Get-ApplyRemainingArgList -CommandName health-check -ArgList $RemainingArgs -AllowedValueFlags @('--min-free-bytes'))
    if ($remainingHealthCheckArgs.Count -gt 0) {
      Write-NucleusError -CommandName health-check "health-check: unsupported argument '$($remainingHealthCheckArgs[0])'"
      exit 1
    }
    Write-NucleusInfo -CommandName health-check "health-check is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'audit-store' {
    Assert-ApplyBoundFlagSet -CommandName audit-store -BoundParameters $PSBoundParameters -AllowedParams @(
      'Help'
    )
    if ($Help.IsPresent) {
      Get-Help $PSCommandPath -Detailed
      exit 0
    }
    $remainingAuditStoreArgs = @(Get-ApplyRemainingArgList -CommandName audit-store -ArgList $RemainingArgs -AllowedValueFlags @())
    if ($remainingAuditStoreArgs.Count -gt 0) {
      Write-NucleusError -CommandName audit-store "audit-store: unsupported argument '$($remainingAuditStoreArgs[0])'"
      exit 1
    }
    Write-NucleusInfo -CommandName audit-store "audit-store is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'status' {
    Assert-ApplyBoundFlagSet -CommandName status -BoundParameters $PSBoundParameters -AllowedParams @(
      'Help', 'History', 'Json'
    )
    if ($Help.IsPresent) {
      Get-Help $PSCommandPath -Detailed
      exit 0
    }
    $statusExit = Invoke-ApplyStatus -ExplicitHistory $statusHistorySpecified -Count $statusHistoryCount -AsJson $statusJson
    exit [int]$statusExit
  }
  'apply' {
    Assert-ApplyBoundFlagSet -CommandName apply -BoundParameters $PSBoundParameters -AllowedParams @(
      'Help', 'AiSync', 'NoAiSync', 'ReplicaSync', 'NoReplicaSync', 'StoreAudit', 'NoStoreAudit',
      'HealthCheck', 'NoHealthCheck', 'VmSync', 'NoVmSync', 'VmSetup', 'NoVmSetup',
      'MinFreeBytes', 'TargetUser', 'Username'
    )
    if ($Help.IsPresent) {
      Get-Help $PSCommandPath -Detailed
      exit 0
    }
    $remainingApplyArgs = @(Get-ApplyRemainingArgList -CommandName apply -ArgList $RemainingArgs -AllowedValueFlags @('--min-free-bytes', '--target-user', '--username'))
    if ($remainingApplyArgs.Count -gt 0) {
      Write-NucleusError -CommandName apply "apply: unsupported argument '$($remainingApplyArgs[0])'"
      exit 1
    }
    Write-NucleusInfo -CommandName apply "apply is handled by the Windows host orchestrator (src/hosts/Windows/apply.ps1); exiting 0"
    exit 0
  }
}
