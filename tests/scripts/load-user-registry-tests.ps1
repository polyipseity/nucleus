#Requires -Version 7.4
# PowerShell entry point for load-user-registry shell parity tests.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$bash = Get-Command -Name bash -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: bash may be absent on non-POSIX hosts; explicit throw below
if (-not $bash) {
  throw 'bash is required to run load-user-registry-tests.ps1'
}

$testScript = Join-Path $PSScriptRoot 'load-user-registry-tests.sh'
& $bash.Source $testScript
exit $LASTEXITCODE
