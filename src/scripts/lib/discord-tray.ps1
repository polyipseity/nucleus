# Converge Discord's system-tray icon visibility by editing its settings.json.
# Discord rewrites settings.json on launch, so this must run while Discord is
# closed (activation runs at login/apply, before the app opens — acceptable).
#
# Usage: discord-tray.ps1 <visible> [appKey]
#   visible: $true/$false (or "true"/"false")
#   appKey:  "Discord" (stable) or "Discord Canary" (canary); defaults to stable.

[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory = $true)]
  $Visible,
  [Parameter(Position = 1)]
  [string]$AppKey = 'Discord'
)

$ErrorActionPreference = 'Stop'

$visBool = $false
switch ($Visible.ToString().ToLower()) {
  'true' { $visBool = $true }
  '1' { $visBool = $true }
  'visible' { $visBool = $true }
  'false' { $visBool = $false }
  '0' { $visBool = $false }
  'hidden' { $visBool = $false }
  default { throw "discord-tray.ps1: invalid visible arg '$Visible'" }
}

if ($AppKey -match 'Canary') {
  $configDir = Join-Path $env:APPDATA 'discordcanary'
} else {
  $configDir = Join-Path $env:APPDATA 'discord'
}
$config = Join-Path $configDir 'settings.json'

if (-not (Test-Path -LiteralPath $configDir)) {
  New-Item -Path $configDir -ItemType Directory -Force > $null
}
$obj = if (Test-Path -LiteralPath $config) {
  Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
} else {
  @{}
}
if ($obj.ContainsKey('systemTray') -and [bool]$obj.systemTray -eq $visBool) {
  exit 0
}
$obj['systemTray'] = $visBool
$obj | ConvertTo-Json -Depth 5 | Set-Content -Path $config -Encoding UTF8
exit 0
