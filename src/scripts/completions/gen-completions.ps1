<#
.SYNOPSIS
  Regenerates the generated completer flag inventory in profile.ps1.

.DESCRIPTION
  The flag inventories behind the Register-ArgumentCompleter blocks in
  src/scripts/shell/profile.ps1 are generated, not hand-maintained. This script
  rewrites the region between the '# --- BEGIN GENERATED completer flag
  inventory ---' and '# --- END GENERATED ---' markers with one
  $nucleus<Cmd>Flags array per nucleus-* command, alphabetically sorted with one
  flag per line, from an authoritative override map. Commands absent from the
  map fall back to parsing .PARAMETER entries from their comment-based help
  (kebab-cased, always including --help). The file's line endings (CRLF or LF)
  and UTF-8 encoding are preserved. Behavioral completer glue (subcommand
  state, services.json reads) lives outside the markers and is never touched.

  In -Check mode the script regenerates in memory and compares against the
  on-disk file, listing every diff and exiting 1 on drift, 0 when up to date.
  Check step 10-completions-fresh runs this script in -Check mode, so a stale
  inventory fails check.sh / check.ps1.

.PARAMETER Help
  Shows this help and exits 0.

.PARAMETER Check
  Compares the regenerated inventory against the on-disk file without writing.

.EXAMPLE
  .\gen-completions.ps1

  Regenerates src/scripts/shell/profile.ps1 in place.

.EXAMPLE
  .\gen-completions.ps1 -Check

  Reports whether the inventory is up to date; used by check step 10-completions-fresh.
#>
[CmdletBinding()]
param(
  [Alias("h")]
  [switch]$Help,
  [switch]$Check
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
if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
  Write-NucleusError "profile.ps1 not found at $profilePath"
  exit 1
}

# ---------------------------------------------------------------------------
# Command inventory and authoritative flag map
# ---------------------------------------------------------------------------

function Get-NucleusCommandList {
  return @(
    'ai',
    'apply',
    'bootstrap',
    'check',
    'cloud',
    'config',
    'gc',
    'gs-pdf-opt',
    'service-watchdog',
    'svc',
    'test',
    'update',
    'vm'
  )
}

function Get-NucleusFlagMap {
  return @{
    'ai' = @('--dry-run', '--gc-only', '--help', '--json', '--no-gc-only', '--ollama-profile', '--profile')
    'apply' = @('--ai-sync', '--help', '--no-ai-sync', '--no-replica-sync', '--no-store-audit', '--no-vm-setup', '--no-vm-sync', '--replica-sync', '--store-audit', '--target-user', '--username', '--vm-setup', '--vm-sync')
    'bootstrap' = @('--ai-sync', '--apply', '--help', '--no-ai-sync', '--no-apply', '--no-replica-sync', '--replica-sync', '--target-user')
    'check' = @('--fail-fast', '--full', '--help', '--no-fail-fast', '--online', '--scoped', '--skip-steps')
    'cloud' = @('--apply', '--help', '--no-apply')
    'config' = @('--help')
    'gc' = @('--dry-run', '--duperemove-gc', '--expiry', '--generations-keep', '--git-cache-gc', '--help', '--hm-expiry', '--hm-gc', '--hm-generations-keep', '--journald-gc', '--log-compress', '--log-gc', '--log-max-files', '--log-max-size', '--nix-artifacts-gc', '--nix-expiry', '--nix-gc', '--no-dry-run', '--no-duperemove-gc', '--no-git-cache-gc', '--no-hm-gc', '--no-journald-gc', '--no-log-gc', '--no-nix-artifacts-gc', '--no-nix-gc', '--no-ollama-gc', '--no-sccache-gc', '--no-system-gc', '--no-tool-cache-gc', '--no-vm-data-gc', '--no-vm-gc', '--no-wallpaper-gc', '--ollama-gc', '--sccache-gc', '--system-gc', '--system-generations-keep', '--tool-cache-gc', '--vm-data-gc', '--vm-gc', '--wallpaper-gc')
    'gs-pdf-opt' = @('--help', '--preset', '--rm-bak')
    'service-watchdog' = @('--domain', '--help', '--oneshot')
    'svc' = @('--help', '--json', '--system', '--user', '--verbose')
    'test' = @('-q', '--fail-fast', '--help', '--no-fail-fast', '--quiet', '--skip-steps')
    'update' = @('--flake', '--help', '--list-sections', '--no-flake', '--no-sops', '--sections', '--sops', '--verify', '--verify-installed')
    'vm' = @('--accept-gsi-license', '--accelerator', '--adb-keys', '--allow-shrink', '--dry-run', '--fake-wifi', '--fake-wifi-revert', '--force', '--gc', '--gc-data', '--gc-disabled', '--gapps', '--headful', '--help', '--json', '--magisk', '--mido-patch-file', '--mido-script', '--no-accept-gsi-license', '--no-gc', '--no-gc-data', '--no-gc-disabled', '--no-headful', '--repo-root', '--root', '--vm-dir-override', '--windows-iso', '--windows-iso-retries', '--windows-iso-source')
  }
}

# ---------------------------------------------------------------------------
# Flag derivation helpers
# ---------------------------------------------------------------------------

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

function ConvertTo-KebabCase {
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )
  return [regex]::Replace($Name, '(?<!^)([A-Z])', '-$1').ToLowerInvariant()
}

function Get-ParamDerivedFlag {
  param(
    [Parameter(Mandatory)]
    [string]$ScriptPath
  )
  if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
    return @('--help')
  }
  $content = [System.IO.File]::ReadAllText($ScriptPath)
  $paramMatches = [regex]::Matches($content, '(?m)^\.PARAMETER\s+([A-Za-z0-9]+)')
  $flags = [System.Collections.Generic.List[string]]::new()
  $flags.Add('--help')
  foreach ($paramMatch in $paramMatches) {
    $flagName = ConvertTo-KebabCase -Name $paramMatch.Groups[1].Value
    $flags.Add($flagName)
  }
  return @($flags | Sort-Object -Unique)
}

function Get-GeneratedRegion {
  param(
    [Parameter(Mandatory)]
    [string[]]$Commands,
    [Parameter(Mandatory)]
    [hashtable]$FlagMap,
    [Parameter(Mandatory)]
    [string]$ScriptsDir,
    [Parameter(Mandatory)]
    [string]$Eol
  )
  $blocks = [System.Collections.Generic.List[string]]::new()
  foreach ($command in $Commands) {
    $varName = 'nucleus' + (ConvertTo-PascalCase $command) + 'Flags'
    # WHY: an if-expression unrolls a single-element array to a scalar; under
    # StrictMode (check-lib.ps1) the scalar has no native .Count, so the whole
    # expression is wrapped in @() to force an array result.
    $flags = @(if ($FlagMap.ContainsKey($command)) {
      @($FlagMap[$command] | Sort-Object)
    } else {
      Get-ParamDerivedFlag -ScriptPath (Join-Path $ScriptsDir "$command.ps1")
    })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("`$$varName = @(")
    for ($i = 0; $i -lt $flags.Count; $i++) {
      # No trailing comma: @( 'a', 'b', ) is a parse error in PowerShell.
      $comma = if ($i -lt $flags.Count - 1) { ',' } else { '' }
      $lines.Add("  '$($flags[$i])'$comma")
    }
    $lines.Add(')')
    $blocks.Add(($lines -join $Eol) + $Eol + $Eol)
  }
  return '# GENERATED by src/scripts/completions/gen-completions.ps1 - do not hand-edit.' + $Eol + ($blocks -join '')
}

# ---------------------------------------------------------------------------
# Region regeneration
# ---------------------------------------------------------------------------

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
$flagMap = Get-NucleusFlagMap
$scriptsDir = Join-Path $repoRoot 'scripts'
$region = Get-GeneratedRegion -Commands $commands -FlagMap $flagMap -ScriptsDir $scriptsDir -Eol $eol
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
