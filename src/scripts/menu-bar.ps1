<#
.SYNOPSIS
  Unified menu-bar / tray icon visibility management for Windows.

.DESCRIPTION
  Provides a uniform CLI for listing, showing, hiding, and verifying menu-bar /
  tray icon visibility across hosts, driven by src/modules/apps.json, the
  canonical registry.  This mirrors autostart.ps1 but targets the app's native
  menu-bar / tray icon preference rather than auto-start.

  Semantic difference from auto-start (driving constraint):
    Auto-start is OR — app-native OR our Run key ⇒ app launches, so we DISABLE
    the native setting and own a separate mechanism.
    Icon visibility is AND — the icon shows only if (app-native show setting =
    desired) AND (OS allows it). There is no separate "our mechanism"; the
    app's native preference IS the control.  We therefore SET the native
    preference to the desired state and never disable it.  Inverted keys are
    expressed via iconVisibleValue / iconHiddenValue, not via a disable flag.

  Windows note: tray-icon visibility is app-specific and often has no universal
  OS toggle.  A Windows entry with a statusIcon block either declares a host
  script (`activation-script`) that sets the app's native tray setting, or is
  `manual`: no script can converge it and no readable preference exists to
  verify against, exactly like autostart's macos-system-extension.

.PARAMETER Action
  The operation to perform: list, status, show, hide, apply, verify.

.PARAMETER AppName
  One or more app keys to target.  Required for show/hide; optional for
  status/verify — defaults to all.

.PARAMETER Json
  Output machine-readable JSON instead of formatted tables.

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\menu-bar.ps1 list
  .\menu-bar.ps1 status Parsec,Steam
  .\menu-bar.ps1 hide Parsec
  .\menu-bar.ps1 show Steam
  .\menu-bar.ps1 apply
  .\menu-bar.ps1 verify
  .\menu-bar.ps1 list -Json

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'status', 'show', 'hide', 'apply', 'verify')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$AppName = @(),

  [switch]$Json,

  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (list, status, show, hide, apply, verify)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.Parent.FullName }
$AppsJson = Join-Path $RepoRoot "src\modules\apps.json"
$NucleusHost = 'Windows'

# Read and parse registry
if (-not (Test-Path $AppsJson)) {
  throw "menu-bar: app registry not found at $AppsJson"
}
$RegistryRaw = Get-Content $AppsJson -Raw | ConvertFrom-Json -AsHashtable

# Filter to Windows-relevant apps that declare a statusIcon block
$Registry = @{}
foreach ($key in $RegistryRaw.Keys) {
  if ($key.StartsWith('$')) { continue }
  $entry = $RegistryRaw[$key]
  if ($entry -is [hashtable] -and $entry.ContainsKey('hosts') -and $entry.hosts.ContainsKey($NucleusHost) -and $entry.hosts[$NucleusHost].type -ne 'omitted') {
    $hostEntry = $entry.hosts[$NucleusHost]
    if ($hostEntry.ContainsKey('statusIcon') -and $null -ne $hostEntry.statusIcon) {
      $Registry[$key] = @{
        displayName = $entry.displayName
        description = $entry.description
        hostEntry   = $hostEntry
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Windows native preference helpers (SET, never disable)
# ---------------------------------------------------------------------------

# MenuBarNativeSet — Write the native preference to the desired state.
# Never disables the native setting; SETs it.
function Set-MenuBarNative {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([int])]
  param([string]$Key, [hashtable]$Entry, [bool]$Visible)
  $icon = $Entry.hostEntry.statusIcon
  $kind = $icon.kind
  if ($kind -eq 'manual') {
    Write-NucleusInfo -CommandName 'menu-bar' "$Key — manual icon entry; not auto-provisioned (set in the app's UI)"
    return 0
  }
  # SupportsShouldProcess gates every mutation below, so -WhatIf reports what
  # would be written without running a script.
  if (-not $PSCmdlet.ShouldProcess($Key, 'set menu bar icon state')) {
    return 0
  }
  switch ($kind) {
    'activation-script' {
      $script = $icon.script
      if (-not [string]::IsNullOrEmpty($script)) {
        $resolvedScript = if ([System.IO.Path]::IsPathRooted($script)) {
          $script
        } else {
          Join-Path $RepoRoot $script
        }
        if (-not (Test-Path -LiteralPath $resolvedScript)) {
          Write-NucleusWarning "$Key — activation-script not found: $resolvedScript"
          return 1
        }
        & $resolvedScript $Visible $Key
        Write-NucleusInfo -CommandName 'menu-bar' "set $Key icon via activation-script"
      }
    }
    default {
      Write-NucleusWarning "$Key — unsupported statusIcon kind '$kind' on host '$NucleusHost'"
      return 1
    }
  }
  return 0
}

# MenuBarActualVisible — $true/$false whether the native preference matches the
# desired visible value.
function Get-MenuBarActualVisible {
  param([hashtable]$Entry)
  $icon = $Entry.hostEntry.statusIcon
  $kind = $icon.kind
  if ($kind -eq 'manual') {
    return 'manual'
  }
  # No Windows-launchable status-icon kind exposes a readable native preference
  # ('activation-script' runs a host script we cannot query), so the icon state
  # cannot be probed — report no match and let verify surface the gap.
  return $false
}

# ---------------------------------------------------------------------------
# Per-app state resolution
# ---------------------------------------------------------------------------

# MenuBarConverge — Apply declared icon state for one app.
# SETs the native preference to the desired state; never disables it.
function Invoke-MenuBarConverge {
  param([string]$Key, [hashtable]$Entry)
  $visible = [bool]$Entry.hostEntry.statusIcon.iconVisible
  try {
    return (Set-MenuBarNative -Key $Key -Entry $Entry -Visible $visible)
  } catch {
    Write-NucleusError "$Key — $($_.Exception.Message)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Action implementations
# ---------------------------------------------------------------------------

function Resolve-AppNameList {
  param([string[]]$Names)
  $results = @{}
  if ($Names.Count -eq 0) {
    foreach ($key in $Registry.Keys) { $results[$key] = $Registry[$key] }
    return $results
  }
  foreach ($name in $Names) {
    if ($Registry.ContainsKey($name)) {
      $results[$name] = $Registry[$name]
    } else {
      $results["ERROR:$name"] = @{ displayName = $name; hostEntry = @{ error = 'app not found in registry (or has no statusIcon block)' } }
    }
  }
  return $results
}

function Format-ListTable {
  param([hashtable]$Results)
  if ($Json) {
    $jsonObj = @{ version = 1; apps = @{} }
    foreach ($key in $Results.Keys) {
      if ($key -like 'ERROR:*') { continue }
      $jsonObj.apps[$key] = @{
        displayName     = $Results[$key].displayName
        actualVisible   = (Get-MenuBarActualVisible -Entry $Results[$key])
        declaredVisible = $Results[$key].hostEntry.statusIcon.iconVisible
      }
    }
    return ($jsonObj | ConvertTo-Json -Depth 3 -Compress)
  }
  $lines = @()
  $lines += "{0,-22} {1,-10} {2,-10} {3}" -f 'ID', 'Actual', 'Declared', 'Name'
  $lines += '-' * 70
  foreach ($key in $Results.Keys) {
    if ($key -like 'ERROR:*') {
      $lines += "{0,-22} {1,-10} {2,-10} {3}" -f $key, 'n/a', '-', $Results[$key].displayName
    } else {
      $actual = Get-MenuBarActualVisible -Entry $Results[$key]
      $declared = $Results[$key].hostEntry.statusIcon.iconVisible
      $lines += "{0,-22} {1,-10} {2,-10} {3}" -f $key, $actual, $declared, $Results[$key].displayName
    }
  }
  return $lines -join "`n"
}

switch ($Action) {
  'list' {
    $resolved = Resolve-AppNameList -Names $AppName
    Write-Output (Format-ListTable -Results $resolved)
  }

  'status' {
    $resolved = Resolve-AppNameList -Names $AppName
    $hasError = $false
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-NucleusWarning "$($resolved[$key].displayName) — $($resolved[$key].hostEntry.error)"
        $hasError = $true
        continue
      }
      $visible = Get-MenuBarActualVisible -Entry $resolved[$key]
      Write-Output ("{0,-22} {1,-10} {2}" -f $key, $visible, $resolved[$key].displayName)
    }
    if ($hasError -and -not $Json) { exit 1 }
  }

  { @('show', 'hide') -contains $_ } {
    if ($AppName.Count -eq 0) {
      throw "missing app name for '$Action'"
    }
    $resolved = Resolve-AppNameList -Names $AppName
    $overallExit = 0
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-NucleusError "$($resolved[$key].displayName) — app not found in registry"
        $overallExit = 1
        continue
      }
      $entry = $Registry[$key]
      # Override the declared iconVisible flag with the requested action for this run.
      $entry.hostEntry.statusIcon.iconVisible = ($Action -eq 'show')
      try {
        if ((Invoke-MenuBarConverge -Key $key -Entry $entry) -ne 0) {
          Write-NucleusError "$key — $Action failed"
          $overallExit = 1
        } elseif ($Json) {
          Write-Output (@{ version = 1; $key = @{ success = $true } } | ConvertTo-Json -Compress -Depth 3)
        }
      } catch {
        Write-NucleusError "$key — $($_.Exception.Message)"
        $overallExit = 1
      }
    }
    if ($overallExit -ne 0) { exit $overallExit }
  }

  'apply' {
    $overallExit = 0
    foreach ($key in $Registry.Keys) {
      try {
        if ((Invoke-MenuBarConverge -Key $key -Entry $Registry[$key]) -ne 0) { $overallExit = 1 }
      } catch {
        Write-NucleusError "$key — $($_.Exception.Message)"
        $overallExit = 1
      }
    }
    if ($overallExit -ne 0) { exit $overallExit }
  }

  'verify' {
    $resolved = Resolve-AppNameList -Names $AppName
    $drift = $false
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') { continue }
      $declared = [bool]$Registry[$key].hostEntry.statusIcon.iconVisible
      $actual = Get-MenuBarActualVisible -Entry $Registry[$key]
      if ($actual -eq 'manual') {
        # Manual entries are declared but not auto-provisioned; no drift check.
        continue
      }
      if ($declared -ne $actual) {
        $drift = $true
        Write-NucleusWarning "$key — drift: declared iconVisible=$declared, actual=$actual"
      }
    }
    if (-not $drift) {
      Write-NucleusInfo -CommandName 'menu-bar' "all app icons converged to declared state"
    }
    if ($drift) { exit 1 }
  }
}
