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

$configFile = Join-Path $HOME ".local" "state" "nucleus" "config.json"

function Ensure-ConfigDir {
  $dir = Split-Path $configFile -Parent
  if (-not (Test-Path $dir)) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
  }
}

function Get-ConfigValue {
  if (-not (Test-Path $configFile)) {
    if ($Arguments.Count -eq 0) { return }
    exit 1
  }
  $cfg = Get-Content -Raw $configFile | ConvertFrom-Json
  if ($Arguments.Count -eq 0) {
    $cfg | ConvertTo-Json
    return
  }
  $keys = $Arguments[0] -split '\.'
  $val = $cfg
  foreach ($k in $keys) {
    $val = $val.$k
    if ($null -eq $val) { exit 1 }
  }
  $val | ConvertTo-Json -Compress
}

function Set-ConfigValue {
  if ($Arguments.Count -lt 2) {
    Write-Error "Usage: nucleus-config set <section.key> <value>"
    exit 1
  }
  Ensure-ConfigDir
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

function List-ConfigValues {
  if (-not (Test-Path $configFile)) { return }
  $cfg = Get-Content -Raw $configFile | ConvertFrom-Json
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
  Flatten $cfg ""
}

switch ($Command) {
  'get' { Get-ConfigValue }
  'set' { Set-ConfigValue }
  'list' { List-ConfigValues }
  default {
    Write-Error "Usage: nucleus-config get [<section.key>]|set <section.key> <value>|list"
    exit 1
  }
}
