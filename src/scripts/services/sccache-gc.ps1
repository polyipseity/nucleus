# Daily sccache cache clearing for Windows scheduled tasks and manual use.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleDir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\hosts\Windows\modules'
. (Join-Path -Path $moduleDir -ChildPath 'Invoke-SccacheManagement.ps1')

Clear-SccacheCache
