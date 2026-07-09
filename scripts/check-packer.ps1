<#
.SYNOPSIS
  Validate Packer template formatting and configuration.

.DESCRIPTION
  With no arguments, checks all .pkr.hcl files under src/vms/. With arguments,
  checks only the provided paths.

  Runs two phases:
    1. packer fmt -check — verify formatting of .pkr.hcl files.
    2. packer init + packer validate — verify each template directory resolves
       plugins and produces a valid plan.

  The macOS template (src/vms/macos/) uses the Tart plugin and is only validated
  on macOS hosts.

.PARAMETER Paths
  Optional file paths to check. When omitted, all .pkr.hcl files under src/vms/
  are checked.

.EXAMPLE
  pwsh -File scripts/check-packer.ps1

.EXAMPLE
  pwsh -File scripts/check-packer.ps1 src/vms/nixos/template.pkr.hcl

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on any Packer format or validation failure.
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @()
)

$ErrorActionPreference = 'Stop'

# Determine repository root — prefer env var, fall back to parent of script dir.
$repoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
}
Set-Location -Path $repoRoot

# ---------------------------------------------------------------------------
# Phase 1: Formatting check
# ---------------------------------------------------------------------------
if ($Paths.Count -gt 0) {
  Write-Output 'Checking Packer formatting for specified paths...'
  & packer fmt -check $Paths
  if ($LASTEXITCODE -ne 0) {
    throw 'Packer formatting check failed for specified paths.'
  }
} else {
  Write-Output 'Checking Packer formatting for all templates...'
  & packer fmt -check -recursive src/vms/
  if ($LASTEXITCODE -ne 0) {
    throw 'Packer formatting check failed.'
  }
}

# ---------------------------------------------------------------------------
# Phase 2: Template validation
# ---------------------------------------------------------------------------
function Test-PackerDir {
  param([string]$Dir)
  Write-Output "Validating $Dir..."
  Push-Location -Path $Dir
  try {
    & packer init .
    if ($LASTEXITCODE -ne 0) {
      throw "packer init failed in $Dir"
    }
    # Required -var flags depend on the template directory
    $varArgs = switch -Wildcard ($Dir) {
      '*nixos'   { @('guest_username=dummy', 'guest_password=dummy', 'nixos_iso_url=https://dummy.iso', 'nixos_iso_checksum=none') }
      '*windows' { @('windows_iso=dummy.iso') }
      '*macos'   { @('macos_version=14.0', 'vm_name=dummy', 'cpus=2', 'memory_gib=4', 'disk_size_gib=40', 'guest_username=dummy', 'guest_password=dummy', 'ssh_username=dummy', 'ssh_password=dummy', 'tart_image_ref=dummy') }
      default    { @() }
    }
    $validateArgs = @('validate') + ($varArgs | ForEach-Object { @('-var', $_) }) + @('.')
    & packer $validateArgs
    if ($LASTEXITCODE -ne 0) {
      throw "packer validate failed in $Dir"
    }
  } finally {
    Pop-Location
  }
}

Test-PackerDir -Dir 'src/vms/nixos'
Test-PackerDir -Dir 'src/vms/windows'

# macOS template uses the Tart plugin which is macOS-only.
$isMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription -match 'darwin|macOS'
if (-not $isMacOSHost) {
  if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::MacOSX) {
    $isMacOSHost = $true
  }
}

if ($isMacOSHost) {
  Test-PackerDir -Dir 'src/vms/macos'
} else {
  Write-Output 'Skipping macOS Packer template validation (requires Tart plugin on macOS)'
}

Write-Output 'All Packer checks passed.'
