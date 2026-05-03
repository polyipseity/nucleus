<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.
#>
[CmdletBinding()]
param([string]$ConfigDir = $PSScriptRoot, [string[]]$ConfigFiles = @("system.dsc.yml", "user.dsc.yml"), [switch]$Help, [string]$ModuleDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\modules\windows"))

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }
. (Join-Path -Path ((Resolve-Path -Path $ModuleDir).Path) -ChildPath "common.ps1")
$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
foreach ($configFile in $ConfigFiles) {
  Invoke-NucleusWingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile)
}
