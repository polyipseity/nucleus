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

  [int]$History,

  [switch]$Json,

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

function Assert-ApplyKnownFlagSet {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [string[]]$ArgList,
    [string[]]$KnownSwitches,
    [string[]]$KnownValueFlags
  )
  $i = 0
  while ($i -lt @($ArgList).Count) {
    $arg = $ArgList[$i]
    if ($arg -eq '-h' -or $arg -eq '--help') {
      Get-Help $PSCommandPath -Detailed
      exit 0
    }
    $matchedValueFlag = $false
    foreach ($vf in $KnownValueFlags) {
      if ($arg -eq $vf) {
        if ($i + 1 -ge @($ArgList).Count) {
          Write-NucleusError -CommandName $CommandName "${CommandName}: $vf requires a value"
          exit 1
        }
        $i += 2
        $matchedValueFlag = $true
        break
      }
      if ($arg -like "$vf=*") {
        $i++
        $matchedValueFlag = $true
        break
      }
    }
    if ($matchedValueFlag) { continue }
    if ($KnownSwitches -contains $arg) {
      $i++
      continue
    }
    Write-NucleusError -CommandName $CommandName "${CommandName}: unsupported argument '$arg'"
    exit 1
  }
}

switch ($Action) {
  'health-check' {
    Assert-ApplyKnownFlagSet -CommandName health-check -ArgList $RemainingArgs `
      -KnownSwitches @('--secret-health', '--no-secret-health', '--log-health', '--store-audit', '--no-store-audit') `
      -KnownValueFlags @('--min-free-bytes')
    Write-NucleusInfo -CommandName health-check "health-check is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'audit-store' {
    Assert-ApplyKnownFlagSet -CommandName audit-store -ArgList $RemainingArgs -KnownSwitches @() -KnownValueFlags @()
    Write-NucleusInfo -CommandName audit-store "audit-store is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'status' {
    $statusExit = Invoke-ApplyStatus -ExplicitHistory $statusHistorySpecified -Count $statusHistoryCount -AsJson $statusJson
    exit [int]$statusExit
  }
  'apply' {
    Assert-ApplyKnownFlagSet -CommandName apply -ArgList $RemainingArgs `
      -KnownSwitches @('--ai-sync', '--no-ai-sync', '--replica-sync', '--no-replica-sync', '--store-audit', '--no-store-audit', '--health-check', '--no-health-check', '--vm-sync', '--no-vm-sync', '--vm-setup', '--no-vm-setup') `
      -KnownValueFlags @('--min-free-bytes', '--target-user', '--username')
    Write-NucleusInfo -CommandName apply "apply is handled by the Windows host orchestrator (src/hosts/Windows/apply.ps1); exiting 0"
    exit 0
  }
}
