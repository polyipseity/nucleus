<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Orchestrates the Windows configuration lifecycle in a single script:
    1. Load helper functions from $ModuleDir\common.ps1 (dot-sourced).
    2. Resolve each DSC config file relative to $ConfigDir.
    3. Pass each file to Invoke-NucleusWingetConfiguration, which substitutes
       the __NUCLEUS_ACTIVE_WALLPAPER__ token and runs `winget configure`.
  The script is idempotent: re-running it re-applies all DSC resources and
  converges any drift from the desired state.

.PARAMETER ConfigDir
  Directory that contains the DSC YAML files.  Defaults to the directory
  containing this script ($PSScriptRoot).

.PARAMETER ConfigFiles
  Ordered list of DSC YAML filenames to apply.  Defaults to
  @('system.dsc.yml', 'user.dsc.yml').  Filenames are resolved relative to
  $ConfigDir.

.PARAMETER ModuleDir
  Path to the directory containing common.ps1 and other Windows module
  helpers.  Defaults to ..\..\modules\windows relative to $PSScriptRoot.

.PARAMETER Help
  When present, prints this help text and exits without applying anything.

.EXAMPLE
  # Apply with defaults (both DSC files, from the script's own directory):
  .\apply.ps1

.EXAMPLE
  # Apply only the user-level DSC file:
  .\apply.ps1 -ConfigFiles @('user.dsc.yml')
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
