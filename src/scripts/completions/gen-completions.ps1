<#
.SYNOPSIS
  Regenerates the generated completer flag inventory in profile.ps1 from the CLI spec.

.DESCRIPTION
  Rewrites the generated flag inventory between the BEGIN/END GENERATED markers in
  src/scripts/shell/profile.ps1: one alphabetically sorted $nucleus<Cmd>Flags array per
  nucleus-* command, derived from src/modules/completions/nucleus-cli-spec.json (all
  global and subcommand long flags). Line endings and UTF-8 encoding are preserved, and
  the completer glue outside the markers is never touched.

  -Check regenerates in memory, diffs against the on-disk file, and exits 1 on drift.
  Check step 10-completions-fresh runs it that way, so a stale inventory fails check.

.PARAMETER Check
  Compares the regenerated inventory against the on-disk file without writing.

.PARAMETER ListCommands
  Prints the Windows command names (manifest minus camilladsp-heartbeat), one per line.

.EXAMPLE
  .\gen-completions.ps1 -Check
#>
[CmdletBinding()]
param(
  [Alias('h')]
  [switch]$Help,
  [switch]$Check,
  [switch]$ListCommands
)

$ErrorActionPreference = 'Stop'

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$modulePath = Join-Path $PSScriptRoot '..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..')).Path
}
$profilePath = Join-Path $repoRoot 'src/scripts/shell/profile.ps1'
$manifestPath = Join-Path $repoRoot 'src/modules/completions/nucleus-apps.json'
$specPath = Join-Path $repoRoot 'src/modules/completions/nucleus-cli-spec.json'

if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
  Write-NucleusError "profile.ps1 not found at $profilePath"
  exit 1
}
if (-not (Test-Path -Path $manifestPath -PathType Leaf)) {
  Write-NucleusError "nucleus command manifest not found at $manifestPath"
  exit 1
}
# Spec is the source of truth; if unavailable in a fixture context, generate minimal inventories.
$specAvailable = Test-Path -Path $specPath -PathType Leaf

function Get-NucleusCommandList {
  $manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
  # WHY: camilladsp-heartbeat has no Windows app surface, so PowerShell completers
  # and flag inventories cover the remaining commands only.
  $names = @($manifest.commands | Where-Object { $_ -and $_ -ne 'camilladsp-heartbeat' })
  if ($names.Count -eq 0) {
    Write-NucleusError "nucleus command manifest at $manifestPath contains no commands"
    exit 1
  }
  return $names
}

function Get-NucleusSpecMap {
  $map = @{}
  if (-not $specAvailable) {
    foreach ($command in @(Get-NucleusCommandList)) { $map[$command] = @('--help') }
    return $map
  }
  $spec = Get-Content -Raw -Path $specPath | ConvertFrom-Json
  foreach ($app in @($spec.apps)) {
    if ($null -eq $app -or [string]::IsNullOrWhiteSpace([string]$app.name)) { continue }
    $flags = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($f in @($app.globalFlags)) {
      if ($null -ne $f -and $null -ne $f.long) { $null = $flags.Add([string]$f.long) } # check-suppress:suppression_doc: HashSet.Add returns bool; membership result intentionally discarded
    }
    foreach ($sc in @($app.subcommands)) {
      foreach ($f in @($sc.flags)) {
        if ($null -ne $f -and $null -ne $f.long) { $null = $flags.Add([string]$f.long) } # check-suppress:suppression_doc: HashSet.Add returns bool; membership result intentionally discarded
      }
    }
    # Every app supports --help at the CLI surface; ensure it is present in inventory.
    $null = $flags.Add('--help') # check-suppress:suppression_doc: HashSet.Add returns bool; membership result intentionally discarded
    $map[[string]$app.name] = @($flags | Sort-Object)
  }
  return $map
}

function ConvertTo-PascalCase {
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )
  $parts = $Name.Split('-')
  $cased = [System.Collections.Generic.List[string]]::new()
  foreach ($part in $parts) {
    if ($part.Length -gt 0) {
      $cased.Add($part.Substring(0, 1).ToUpperInvariant() + $part.Substring(1).ToLowerInvariant())
    }
  }
  return ($cased -join '')
}

function Get-GeneratedRegion {
  param(
    [Parameter(Mandatory)]
    [string[]]$Commands,
    [Parameter(Mandatory)]
    [hashtable]$FlagMap,
    [Parameter(Mandatory)]
    [string]$Eol
  )
  $blocks = [System.Collections.Generic.List[string]]::new()
  foreach ($command in $Commands) {
    $varName = 'nucleus' + (ConvertTo-PascalCase $command) + 'Flags'
    $flags = @(if ($FlagMap.ContainsKey($command)) { @($FlagMap[$command] | Sort-Object) } else { @('--help') })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("`$$varName = @(")
    for ($i = 0; $i -lt $flags.Count; $i++) {
      $comma = if ($i -lt $flags.Count - 1) { ',' } else { '' }
      $literal = ([string]$flags[$i]).Replace("'", "''")
      $lines.Add("  '$literal'$comma")
    }
    $lines.Add(')')
    $blocks.Add(($lines -join $Eol) + $Eol + $Eol)
  }
  return '# GENERATED by src/scripts/completions/gen-completions.ps1 - do not hand-edit.' + $Eol + ($blocks -join '')
}

if ($ListCommands) {
  Get-NucleusCommandList | ForEach-Object { $_ }
  return
}

$text = [System.IO.File]::ReadAllText($profilePath)
$eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$beginMarker = '# --- BEGIN GENERATED completer flag inventory ---'
$endMarker = '# --- END GENERATED ---'
$beginIndex = $text.IndexOf($beginMarker)
$endIndex = $text.IndexOf($endMarker)
if ($beginIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -lt $beginIndex) {
  Write-NucleusError "generated-region markers not found in $profilePath"
  exit 1
}

$commands = @(Get-NucleusCommandList)
$flagMap = Get-NucleusSpecMap
$region = Get-GeneratedRegion -Commands $commands -FlagMap $flagMap -Eol $eol
$newText = $text.Substring(0, $beginIndex) + $beginMarker + $eol + $region + $endMarker + $text.Substring($endIndex + $endMarker.Length)

if ($Check) {
  $diff = Compare-Object ([string[]]($text -split $eol)) ([string[]]($newText -split $eol))
  if ($null -ne $diff) {
    Write-NucleusInfo 'profile.ps1 is out of date:'
    foreach ($diffLine in $diff) {
      $side = if ($diffLine.SideIndicator -eq '=>') { 'expected' } else { 'actual' }
      Write-Output "  ${side}: $($diffLine.InputObject)"
    }
    exit 1
  }
  Write-NucleusInfo 'profile.ps1 is up to date.'
  exit 0
}

$tmpFile = [System.IO.Path]::GetTempFileName()
try {
  [System.IO.File]::WriteAllText($tmpFile, $newText, [System.Text.UTF8Encoding]::new($false))
  Move-Item -Path $tmpFile -Destination $profilePath -Force
} catch {
  if (Test-Path -Path $tmpFile -PathType Leaf) {
    Remove-Item -Path $tmpFile -Force
  }
  throw
}
Write-NucleusInfo "regenerated $profilePath"
