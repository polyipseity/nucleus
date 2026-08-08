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

  The macOS template (src/vms/macOS/) uses the Tart plugin and is only validated
  on macOS hosts.

.PARAMETER Paths
  Optional file paths to check. When omitted, all .pkr.hcl files under src/vms/
  are checked.

.EXAMPLE
  pwsh -File scripts/check-packer.ps1

.EXAMPLE
  pwsh -File scripts/check-packer.ps1 src/vms/NixOS/template.pkr.hcl

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on any Packer format or validation failure.
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @(),

  # Test seam: point the packer_validate annotation check at a different
  # template file (used by tests/scripts/check-packer-annotation-tests.ps1).
  [string]$WindowsTemplateOverride = '',

  # Test seam: run only the packer_validate annotation check, then exit.
  [switch]$AnnotationCheckOnly
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
# packer_validate annotation check (Category 1 machine-parsing invariant)
# ---------------------------------------------------------------------------
# The Windows template sets iso_checksum to "none" because Microsoft publishes
# no stable Windows 11 ISO checksums. That choice is authorized by the
# `# check-suppress:packer_validate:` annotation on the iso_checksum line; this
# script (and its scripts/check-packer.sh twin) is the annotation's machine
# consumer. When the annotation is present, the expected packer "checksum of
# none" warning is hidden from validation output; when iso_checksum resolves
# to "none" without the annotation, the check fails.
$packerWindowsTemplate = if ($WindowsTemplateOverride) {
  $WindowsTemplateOverride
} else {
  Join-Path -Path $repoRoot -ChildPath 'src/vms/Windows/packer.pkr.hcl'
}

function Get-EffectiveChecksum {
  <#
  .SYNOPSIS
    Resolve the effective iso_checksum value of a .pkr.hcl assignment line.
  .DESCRIPTION
    Returns 'none' when the line's value is the literal "none"/'none' or
    references a variable whose default is "none"; returns $null otherwise.
    Inline HCL comments are ignored.
  #>
  param(
    [string]$Line,
    [string[]]$TemplateLines
  )
  $value = ($Line.Split('#')[0] -replace '^\s*iso_checksum\s*=\s*', '').Trim()
  if ($value -in @('"none"', "'none'")) { return 'none' }
  $varMatch = [regex]::Match($value, '^var\.([A-Za-z0-9_]+)')
  if (-not $varMatch.Success) { return $null }
  $varName = $varMatch.Groups[1].Value
  $blockOpen = $false
  foreach ($tpl in $TemplateLines) {
    if ($tpl -match ('^variable\s+"' + [regex]::Escape($varName) + '"')) {
      $blockOpen = $true
      continue
    }
    if ($blockOpen) {
      if ($tpl -match '^\s*default\s*=\s*["'']none[""'']') { return 'none' }
      if ($tpl -match '^\}') { break }
    }
  }
  return $null
}

function Test-PackerValidateAnnotation {
  <#
  .SYNOPSIS
    Enforce the packer_validate annotation on iso_checksum = "none" sites.
  .DESCRIPTION
    Parses the Windows Packer template: every iso_checksum assignment that
    resolves to "none" (skip verification) MUST carry a
    `# check-suppress:packer_validate:` annotation on the same line. Throws
    listing all violations. Returns $true when the annotation was found (which
    authorizes hiding the expected packer warning), $false when no iso_checksum
    assignment exists.
  #>
  param([string]$TemplatePath)
  if (-not (Test-Path -Path $TemplatePath)) { return $false }
  $templateLines = Get-Content -Path $TemplatePath
  $violations = [System.Collections.Generic.List[string]]::new()
  $annotated = $false
  foreach ($line in $templateLines) {
    if ($line -notmatch '^\s*iso_checksum\s*=') { continue }
    $effective = Get-EffectiveChecksum -Line $line -TemplateLines $templateLines
    $hasAnnotation = $line -match '#\s*check-suppress:packer_validate:'
    if ($hasAnnotation) { $annotated = $true }
    if ($effective -eq 'none' -and -not $hasAnnotation) {
      $violations.Add("iso_checksum resolves to 'none' without '# check-suppress:packer_validate:' annotation: $($line.Trim())")
    }
  }
  if ($violations.Count -gt 0) {
    throw ("packer_validate annotation violation(s):`n" + ($violations -join "`n"))
  }
  return $annotated
}

$suppressChecksumWarning = Test-PackerValidateAnnotation -TemplatePath $packerWindowsTemplate

if ($AnnotationCheckOnly) {
  Write-Output 'packer_validate annotation check passed.'
  exit 0
}

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

# Read NixOS ISO digest from lockfile for the current architecture.
$lockfilePath = Join-Path -Path $repoRoot -ChildPath 'src/lockfiles/lockfile.json'
$lockfileData = Get-Content -Path $lockfilePath -Raw | ConvertFrom-Json -AsHashtable
$nixArch = if ([Environment]::Is64BitOperatingSystem) {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
  "$arch-linux"
} else {
  'x86_64-linux'
}
$nixosDigest = if ($lockfileData['vm-setup']['nixos-iso'].$nixArch) {
  $lockfileData['vm-setup']['nixos-iso'].$nixArch.digest
} else {
  'none'
}

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
      '*NixOS'   { @('guest_username=dummy', 'guest_password=dummy', 'guest_hostname=dummy', 'nixos_iso_url=https://dummy.iso', "nixos_iso_checksum=$nixosDigest") }
      '*Windows' { @('windows_iso=dummy.iso', 'hostfwd=dummy', 'guest_hostname=dummy') }
      '*macOS'   { @('macos_version=14.0', 'vm_name=dummy', 'cpus=2', 'memory_gib=4', 'disk_size_gib=40', 'guest_username=dummy', 'guest_password=dummy', 'ssh_username=dummy', 'ssh_password=dummy', 'tart_image_ref=dummy', 'vm_hostname=dummy') }
      default    { @() }
    }
    $validateArgs = @('validate') + ($varArgs | ForEach-Object { @('-var', $_) }) + @('.')
    $validateOutput = @(& packer $validateArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
      $validateOutput | ForEach-Object { Write-Output ($_ -as [string]) }
      throw "packer validate failed in $Dir"
    }
    # Hide the expected "checksum of none" warning when the packer_validate
    # annotation authorizes it (see the annotation check above). Mirrors the
    # _filter_known_packer_warnings awk filter in scripts/check-packer.sh.
    if ($Dir -like '*windows' -and $suppressChecksumWarning) {
      $skip = $false
      foreach ($out in $validateOutput) {
        $text = $out -as [string]
        if ($text -match 'Warning: A checksum of .none. was specified') { $skip = $true; continue }
        if ($skip -and $text -match '\(source code not available\)') { $skip = $false; continue }
        if ($skip) { continue }
        Write-Output $text
      }
    } else {
      $validateOutput | ForEach-Object { Write-Output ($_ -as [string]) }
    }
  } finally {
    Pop-Location
  }
}

Test-PackerDir -Dir 'src/vms/NixOS'
Test-PackerDir -Dir 'src/vms/Windows'

# macOS template uses the Tart plugin which is macOS-only.
$isMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription -match 'darwin|macOS'
if (-not $isMacOSHost) {
  if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::MacOSX) {
    $isMacOSHost = $true
  }
}

if ($isMacOSHost) {
  Test-PackerDir -Dir 'src/vms/macOS'
} else {
  Write-Output 'Skipping macOS Packer template validation (requires Tart plugin on macOS)'
}

Write-Output 'All Packer checks passed.'
