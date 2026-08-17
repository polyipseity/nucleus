<#
.SYNOPSIS
  Unified GUI/user app auto-start management for Windows (Run key / Startup folder).

.DESCRIPTION
  Provides a uniform CLI for listing, enabling, disabling, and verifying
  GUI/user app auto-start across hosts, driven by src/modules/apps.json
  (the canonical registry).  This mirrors svc.ps1 but targets login/boot
  auto-start apps rather than background daemons.

  Policy (driving constraint): we never let an app manage its own startup.
  If an app exposes a native auto-start setting, we disable it (disableNative),
  then control enable/disable through exactly one uniform mechanism we own:
    Windows — a Run-key entry (HKCU\Software\Microsoft\Windows\CurrentVersion\Run)
              or a Startup-folder .lnk we write/remove.

.PARAMETER Action
  The operation to perform: list, status, enable, disable, apply, verify.

.PARAMETER AppName
  One or more app keys to target (required for enable/disable; optional for
  status/verify — defaults to all).

.PARAMETER Json
  Output machine-readable JSON instead of formatted tables.

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\autostart.ps1 list
  .\autostart.ps1 status Parsec,Steam
  .\autostart.ps1 enable Parsec
  .\autostart.ps1 disable Steam
  .\autostart.ps1 apply
  .\autostart.ps1 verify
  .\autostart.ps1 list -Json

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'status', 'enable', 'disable', 'apply', 'verify')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$AppName = @(),

  [switch]$Json,

  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (list, status, enable, disable, apply, verify)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$AppsJson = Join-Path $RepoRoot "src\modules\apps.json"
$NucleusHost = 'Windows'

# Read and parse registry
if (-not (Test-Path $AppsJson)) {
  throw "autostart: app registry not found at $AppsJson"
}
$RegistryRaw = Get-Content $AppsJson -Raw | ConvertFrom-Json -AsHashtable

# Filter to Windows-relevant apps
$Registry = @{}
foreach ($key in $RegistryRaw.Keys) {
  if ($key.StartsWith('$')) { continue }
  $entry = $RegistryRaw[$key]
  if ($entry -is [hashtable] -and $entry.ContainsKey('hosts') -and $entry.hosts.ContainsKey($NucleusHost) -and $entry.hosts[$NucleusHost].type -ne 'omitted') {
    $Registry[$key] = @{
      displayName = $entry.displayName
      description = $entry.description
      hostEntry   = $entry.hosts[$NucleusHost]
    }
  }
}

# ---------------------------------------------------------------------------
# Windows auto-start helpers (our uniform mechanism)
# ---------------------------------------------------------------------------

$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# AppRunKeyValueName — Derive OUR Run-key value name for an app.
# Prefixed with "nucleus-" so it never collides with an app-shipped value
# (e.g. Steam's own "Steam" value), keeping our mechanism distinct and
# removable in isolation.
function AppRunKeyValueName {
  param([string]$Key)
  return "nucleus-$Key"
}

# RunKeyEntryExists — $true/$false whether OUR Run-key value is present.
function Test-RunKeyEntry {
  param([string]$Key)
  $valueName = AppRunKeyValueName -Key $Key
  # check-suppress:suppression_doc: probe -- value may be absent; expected on fresh systems.
  $v = Get-ItemProperty -Path $RunKeyPath -Name $valueName -ErrorAction SilentlyContinue
  return ($null -ne $v)
}

# RunKeyEntryWrite — Create OUR Run-key value pointing at the app path.
function Enable-RunKeyEntry {
  param([string]$Key, [string]$Path)
  if (-not (Test-Path -Path $RunKeyPath)) {
    New-Item -Path $RunKeyPath -Force > $null
  }
  $valueName = AppRunKeyValueName -Key $Key
  Set-ItemProperty -Path $RunKeyPath -Name $valueName -Value $Path
  Write-NucleusInfo -CommandName 'autostart' "enabled $Key via Run key"
}

# RunKeyEntryRemove — Delete OUR Run-key value if present.
function Disable-RunKeyEntry {
  param([string]$Key)
  $valueName = AppRunKeyValueName -Key $Key
  if (Test-RunKeyEntry -Key $Key) {
    # check-suppress:suppression_doc: best-effort removal (value confirmed above but may have been removed concurrently).
    Remove-ItemProperty -Path $RunKeyPath -Name $valueName -ErrorAction SilentlyContinue
    Write-NucleusInfo -CommandName 'autostart' "disabled $Key (removed Run key)"
  }
}

# NativeRunKeyRemove — Delete any app-shipped Run-key value whose data
# references the app path, neutralizing the app's native auto-start.
function Unregister-NativeRunKey {
  param([string]$Path)
  if (-not (Test-Path -Path $RunKeyPath)) { return }
  $base = Split-Path -Path $Path -Leaf
  if ([string]::IsNullOrEmpty($base)) { return }
  # check-suppress:suppression_doc: probe -- Run key may be absent; empty result handled.
  $props = Get-ItemProperty -Path $RunKeyPath -ErrorAction SilentlyContinue
  if ($null -eq $props) { return }
  foreach ($name in $props.PSObject.Properties.Name) {
    if ($name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
    $data = $props.$name
    if ($null -ne $data -and $data -is [string] -and $data.Contains($base)) {
      # check-suppress:suppression_doc: best-effort removal (native app value we neutralize).
      Remove-ItemProperty -Path $RunKeyPath -Name $name -ErrorAction SilentlyContinue
      Write-NucleusInfo -CommandName 'autostart' "neutralized native Run key '$name'"
    }
  }
}

# NativeStartupShortcutRemove — Delete any app-shipped Startup-folder .lnk
# whose target references the app path, neutralizing the app's native auto-start.
function Unregister-NativeStartupShortcut {
  param([string]$Path)
  $startupPath = [Environment]::GetFolderPath('Startup')
  if (-not (Test-Path -Path $startupPath)) { return }
  $base = Split-Path -Path $Path -Leaf
  if ([string]::IsNullOrEmpty($base)) { return }
  # check-suppress:suppression_doc: probe -- Startup folder may be empty; empty result handled.
  $links = Get-ChildItem -Path $startupPath -Filter '*.lnk' -File -ErrorAction SilentlyContinue
  foreach ($link in $links) {
    $target = (New-Object -ComObject WScript.Shell).CreateShortcut($link.FullName).TargetPath
    if ($null -ne $target -and $target.Contains($base)) {
      Remove-Item -Path $link.FullName -Force
      Write-NucleusInfo -CommandName 'autostart' "neutralized native Startup shortcut '$($link.Name)'"
    }
  }
}

# ---------------------------------------------------------------------------
# Per-app state resolution
# ---------------------------------------------------------------------------

# AppActualState — 'enabled'/'disabled' reflecting whether OUR mechanism has it.
function Get-AppActualState {
  param([string]$Key, [hashtable]$Entry)
  $kind = $Entry.hostEntry.kind
  switch ($kind) {
    'run-key' {
      if (Test-RunKeyEntry -Key $Key) { return 'enabled' } else { return 'disabled' }
    }
    'startup-folder' {
      $startupPath = [Environment]::GetFolderPath('Startup')
      $link = Join-Path -Path $startupPath -ChildPath "nucleus-$Key.lnk"
      if (Test-Path -LiteralPath $link) { return 'enabled' } else { return 'disabled' }
    }
    default {
      return 'unknown'
    }
  }
}

# AppConverge — Apply declared state for one app.
function Invoke-AppConverge {
  param([string]$Key, [hashtable]$Entry)
  $kind = $Entry.hostEntry.kind
  $enabled = $Entry.hostEntry.enabled
  $disableNative = $Entry.hostEntry.disableNative
  $path = if ($Entry.hostEntry.ContainsKey('path')) { $Entry.hostEntry.path } else { '' }

  switch ($kind) {
    'run-key' {
      if ($disableNative) {
        # Neutralize any app-shipped Run-key/Startup entry so only our
        # uniform mechanism remains.
        Unregister-NativeRunKey -Path $path
        Unregister-NativeStartupShortcut -Path $path
      }
      if ($enabled) {
        Enable-RunKeyEntry -Key $Key -Path $path
      } else {
        Disable-RunKeyEntry -Key $Key
      }
    }
    'startup-folder' {
      if ($disableNative) {
        Unregister-NativeStartupShortcut -Path $path
        Unregister-NativeRunKey -Path $path
      }
      $startupPath = [Environment]::GetFolderPath('Startup')
      $link = Join-Path -Path $startupPath -ChildPath "nucleus-$Key.lnk"
      if ($enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = $path
        $shortcut.Save()
        Write-NucleusInfo -CommandName 'autostart' "enabled $Key via Startup folder"
      } else {
        if (Test-Path -LiteralPath $link) {
          Remove-Item -Path $link -Force
          Write-NucleusInfo -CommandName 'autostart' "disabled $Key (removed Startup shortcut)"
        }
      }
    }
    default {
      Write-NucleusWarning "$Key — unsupported kind '$kind' on host '$NucleusHost'"
      return 1
    }
  }
  return 0
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
      $results["ERROR:$name"] = @{ displayName = $name; hostEntry = @{ error = 'app not found in registry' } }
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
        displayName = $Results[$key].displayName
        state       = (Get-AppActualState -Key $key -Entry $Results[$key])
        declared    = $Results[$key].hostEntry.enabled
      }
    }
    return ($jsonObj | ConvertTo-Json -Depth 3 -Compress)
  }
  $lines = @()
  $lines += "{0,-22} {1,-10} {2,-8} {3}" -f 'ID', 'State', 'Declared', 'Name'
  $lines += '-' * 70
  foreach ($key in $Results.Keys) {
    if ($key -like 'ERROR:*') {
      $lines += "{0,-22} {1,-10} {2,-8} {3}" -f $key, 'n/a', '-', $Results[$key].displayName
    } else {
      $state = Get-AppActualState -Key $key -Entry $Results[$key]
      $declared = $Results[$key].hostEntry.enabled
      $lines += "{0,-22} {1,-10} {2,-8} {3}" -f $key, $state, $declared, $Results[$key].displayName
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
      $state = Get-AppActualState -Key $key -Entry $resolved[$key]
      Write-Output ("{0,-22} {1,-10} {2}" -f $key, $state, $resolved[$key].displayName)
    }
    if ($hasError -and -not $Json) { exit 1 }
  }

  { @('enable', 'disable') -contains $_ } {
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
      # Override the declared enabled flag with the requested action for this run.
      $entry.hostEntry.enabled = ($Action -eq 'enable')
      try {
        if ((Invoke-AppConverge -Key $key -Entry $entry) -ne 0) {
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
        if ((Invoke-AppConverge -Key $key -Entry $Registry[$key]) -ne 0) { $overallExit = 1 }
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
      $declared = $Registry[$key].hostEntry.enabled
      $actual = Get-AppActualState -Key $key -Entry $Registry[$key]
      $declaredOn = ($declared -eq $true)
      $actualOn = ($actual -eq 'enabled')
      if ($declaredOn -ne $actualOn) {
        $drift = $true
        Write-NucleusWarning "$key — drift: declared enabled=$declaredOn, actual=$actual"
      }
    }
    if (-not $drift) {
      Write-NucleusInfo -CommandName 'autostart' "all apps converged to declared state"
    }
    if ($drift) { exit 1 }
  }
}
