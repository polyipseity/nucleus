<#
.SYNOPSIS
  Manage runtime configuration for nucleus services.

.DESCRIPTION
  Config is stored in ~\.local\state\nucleus\config.json.
  Subcommands: get, set, list.

.PARAMETER Command
  Subcommand: get, set, or list.

.PARAMETER Arguments
  Arguments for the subcommand.

.EXAMPLE
  nucleus-config set camilladsp.heartbeat false
  nucleus-config get camilladsp.heartbeat
  nucleus-config list
#>

param(
  [Parameter(Position = 0)]
  [string]$Command,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$configFile = Join-Path -Path $HOME -ChildPath ".local/state/nucleus/config.json"

# Default values for all known config keys.
# Used as fallback when file/key is absent, so users can discover available options.
$script:Defaults = @{
  camilladsp = @{
    heartbeat = $true
  }
}

function New-ConfigDir {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $dir = Split-Path -Path $configFile -Parent
  if (-not (Test-Path $dir) -and $PSCmdlet.ShouldProcess($dir, 'Create config directory')) {
    New-Item -Path $dir -ItemType Directory -Force > $null
  }
}

function Get-ConfigValue {
  param([string[]]$Arguments)
  $merged = Merge-Config
  if ($Arguments.Count -eq 0) {
    $merged | ConvertTo-Json
    return
  }
  $keys = $Arguments[0] -split '\.'
  $val = $merged
  foreach ($k in $keys) {
    $val = $val.$k
    if ($null -eq $val) { exit 1 }
  }
  $val | ConvertTo-Json -Compress
}

function Merge-Config {
  $merged = $script:Defaults | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  if (-not (Test-Path $configFile)) { return $merged }
  $user = Get-Content -Raw $configFile | ConvertFrom-Json
  return DeepMerge $merged $user
}

function DeepMerge($a, $b) {
  if ($a -is [PSCustomObject] -and $b -is [PSCustomObject]) {
    $result = $a.PSObject.Copy()
    foreach ($prop in $b.PSObject.Properties) {
      if ($null -ne $a.$($prop.Name)) {
        $result.$($prop.Name) = DeepMerge $a.$($prop.Name) $prop.Value
      } else {
        $result | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
      }
    }
    return $result
  }
  return $b
}

function Set-ConfigValue {
  [CmdletBinding(SupportsShouldProcess)]
  param([string[]]$Arguments)
  if ($Arguments.Count -lt 2) {
    Write-NucleusError "Usage: nucleus-config set <section.key> <value>"
    exit 1
  }
  New-ConfigDir
  $key = $Arguments[0]
  $rawValue = $Arguments[1]

  $cfg = @{}
  if (Test-Path $configFile) {
    $cfg = Get-Content -Raw $configFile | ConvertFrom-Json -AsHashtable
  }

  $keys = $key -split '\.'
  $current = $cfg
  for ($i = 0; $i -lt $keys.Count - 1; $i++) {
    if (-not $current.ContainsKey($keys[$i])) {
      $current[$keys[$i]] = @{}
    }
    $current = $current[$keys[$i]]
  }

  # Try to parse as JSON (true/false, numbers), else treat as string.
  try {
    $parsed = $rawValue | ConvertFrom-Json -ErrorAction Stop
    $current[$keys[-1]] = $parsed
  } catch {
    $current[$keys[-1]] = $rawValue
  }

  $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -NoNewline
}

function Out-ConfigValueList {
  $merged = Merge-Config
  function Flatten($obj, $prefix) {
    foreach ($prop in $obj.PSObject.Properties) {
      $key = if ($prefix) { "$prefix.$($prop.Name)" } else { $prop.Name }
      if ($prop.Value -is [PSCustomObject]) {
        Flatten $prop.Value $key
      } elseif ($null -ne $prop.Value) {
        $val = $prop.Value | ConvertTo-Json -Compress
        Write-Output "$key=$val"
      }
    }
  }
  Flatten $merged ""
}

switch ($Command) {
  'get' { Get-ConfigValue $Arguments }
  'set' { Set-ConfigValue $Arguments }
  'list' { Out-ConfigValueList }
  default {
    Write-NucleusError "Usage: nucleus-config get [<section.key>]|set <section.key> <value>|list"
    exit 1
  }
}
