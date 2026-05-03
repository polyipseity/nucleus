[CmdletBinding()]
param(
  [Parameter()]
  [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "..\src\hosts\windows\configuration.dsc.yaml")
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
  throw "winget is required but was not found in PATH."
}

$resolvedConfig = Resolve-Path -Path $ConfigPath

Write-Host "Applying WinGet DSC: $resolvedConfig" -ForegroundColor Cyan
winget configure --accept-configuration-agreements --disable-interactivity "$resolvedConfig"
