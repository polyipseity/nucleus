# check.ps1 — Consolidated repository validation script (Windows).
#
# Thin orchestrator — sources check-lib.ps1 for framework, check-steps.ps1 for step
# registration, then runs the orchestration pipeline.
#
# See check-lib.ps1, step-runner.ps1, and files in check-steps/ for step logic.
#
# Arguments:
#   -Action <all|packer|sh|pwsh>  Which check to run (default: all).
#                     all    Run every check via the step pipeline.
#                     packer Run the Packer template validation (check-packer.ps1).
#                     sh     Run the shell script lint (check-sh.ps1).
#                     pwsh   Run check-pwsh.ps1 + check-pwsh-naming.ps1.
#   --full           Run all checks including whole-repo checks (default).
#   --scoped         Run only path-scopable checks.
#   --fail-fast      Exit immediately on first failure.
#   --no-fail-fast   Accumulate all failures (default).
#   --online         Run online determinism checks.
#   --skip-steps=<ids>  Skip steps with the given comma-separated IDs.
#   (paths)          Files to check; restricts --scoped to matching files.
#                     For subcommands, passed through to the underlying script.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.

#Requires -Version 7.4

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('all', 'packer', 'sh', 'pwsh')]
  [string]$Action = 'all',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @(),

  # Pass-through flags for the inlined packer subcommand (previously check-packer.ps1).
  [string]$WindowsTemplateOverride = '',
  [switch]$AnnotationCheckOnly,
  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$ScriptDir = $PSScriptRoot

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

function Invoke-CheckPacker {
  <#
  .SYNOPSIS
    Validate Packer template formatting and configuration (inlined from check-packer.ps1).
  .DESCRIPTION
    Runs packer fmt -check and packer init + packer validate for VM templates.
    Enforces the packer_validate annotation on iso_checksum = "none" sites.
  #>
  [CmdletBinding()]
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @(),

    # Test seam: point the packer_validate annotation check at a different
    # template file (packer_validate annotation is enforced by check-packer itself).
    [string]$WindowsTemplateOverride = '',

    # Test seam: run only the packer_validate annotation check, then exit.
    [switch]$AnnotationCheckOnly,

    [switch]$ValidateOnly
  )

  Set-Location -Path $RepoRoot

  # -------------------------------------------------------------------------
  # packer_validate annotation check (Category 1 machine-parsing invariant)
  # -------------------------------------------------------------------------
  $packerWindowsTemplate = if ($WindowsTemplateOverride) {
    $WindowsTemplateOverride
  } else {
    Join-Path -Path $RepoRoot -ChildPath 'src/vms/Windows/packer.pkr.hcl'
  }

  function Get-EffectiveChecksum {
    <#
    .SYNOPSIS
      Resolve the effective iso_checksum value of a .pkr.hcl assignment line.
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
        if ($tpl -match "^\s*default\s*=\s*[\""']none[\""']") { return 'none' }
        if ($tpl -match '^\}') { break }
      }
    }
    return $null
  }

  function Test-PackerValidateAnnotation {
    <#
    .SYNOPSIS
      Enforce the packer_validate annotation on iso_checksum = "none" sites.
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
    Write-NucleusInfo -CommandName check-packer 'packer_validate annotation check passed.'
    exit 0
  }

  # -------------------------------------------------------------------------
  # Phase 1: Formatting check (skipped with -ValidateOnly)
  # -------------------------------------------------------------------------
  if (-not $ValidateOnly) {
    if ($Paths.Count -gt 0) {
      Write-NucleusInfo -CommandName check-packer 'Checking Packer formatting for specified paths...'
      & packer fmt -check $Paths
      if ($LASTEXITCODE -ne 0) {
        throw 'Packer formatting check failed for specified paths.'
      }
    } else {
      Write-NucleusInfo -CommandName check-packer 'Checking Packer formatting for all templates...'
      & packer fmt -check -recursive src/vms/
      if ($LASTEXITCODE -ne 0) {
        throw 'Packer formatting check failed.'
      }
    }
  }

  # -------------------------------------------------------------------------
  # Phase 2: Template validation
  # -------------------------------------------------------------------------
  $lockfilePath = Join-Path -Path $RepoRoot -ChildPath 'src/lockfiles/lockfile.json'
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
    <#
    .SYNOPSIS
      Run packer init + packer validate for a single template directory.
    #>
    param(
      [string]$Dir,
      [string]$NixosDigest,
      [bool]$SuppressChecksumWarning
    )
    Write-NucleusInfo -CommandName check-packer "Validating $Dir..."
    Push-Location -Path $Dir
    try {
      & packer init .
      if ($LASTEXITCODE -ne 0) {
        throw "packer init failed in $Dir"
      }
      $varArgs = switch -Wildcard ($Dir) {
        '*NixOS'   { @('guest_username=dummy', 'guest_password=dummy', 'guest_hostname=dummy', 'nixos_iso_url=https://dummy.iso', "nixos_iso_checksum=$NixosDigest") }
        '*Windows' { @('windows_iso=dummy.iso', 'hostfwd=dummy', 'guest_hostname=dummy') }
        '*macOS'   { @('macos_version=14.0', 'vm_id=dummy', 'cpus=2', 'memory_gib=4', 'disk_size_gib=40', 'guest_username=dummy', 'guest_password=dummy', 'ssh_username=dummy', 'ssh_password=dummy', 'tart_image_ref=dummy', 'vm_hostname=dummy') }
        default    { @() }
      }
      $validateArgs = @('validate') + ($varArgs | ForEach-Object { @('-var', $_) }) + @('.')
      $validateOutput = @(& packer $validateArgs 2>&1)
      if ($LASTEXITCODE -ne 0) {
        $validateOutput | ForEach-Object { Write-Output ($_ -as [string]) }
        throw "packer validate failed in $Dir"
      }
      if ($Dir -like '*windows' -and $SuppressChecksumWarning) {
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

  Test-PackerDir -Dir 'src/vms/NixOS' -NixosDigest $nixosDigest -SuppressChecksumWarning $suppressChecksumWarning
  Test-PackerDir -Dir 'src/vms/Windows' -NixosDigest $nixosDigest -SuppressChecksumWarning $suppressChecksumWarning

  $isMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription -match 'darwin|macOS'
  if (-not $isMacOSHost) {
    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::MacOSX) {
      $isMacOSHost = $true
    }
  }

  if ($isMacOSHost) {
    Test-PackerDir -Dir 'src/vms/macOS' -NixosDigest $nixosDigest -SuppressChecksumWarning $suppressChecksumWarning
  } else {
    Write-NucleusInfo -CommandName check-packer 'Skipping macOS Packer template validation (requires Tart plugin on macOS)'
  }

  Write-NucleusInfo -CommandName check-packer 'All Packer checks passed.'
}

function Invoke-CheckSh {
  <#
  .SYNOPSIS
    Lint repository shell scripts with ShellCheck (inlined from check-sh.ps1).
  .DESCRIPTION
    Discovers tracked *.sh files via git ls-files (excluding vendor/) or accepts
    explicit paths. Flags match src/modules/lib/script-tree.nix: -x -S style.
  #>
  [CmdletBinding()]
  param(
    [switch]$Scoped,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
  )

  # check-suppress:suppression_doc: probe whether shellcheck is installed; $null check below throws if absent.
  $shellcheck = Get-Command -Name 'shellcheck' -ErrorAction SilentlyContinue
  if (-not $shellcheck) {
    throw 'shellcheck is required but was not found in PATH (install ShellCheck.ShellCheck via WinGet)'
  }

  Push-Location $RepoRoot
  try {
    if ($Paths.Count -eq 0) {
      if ($Scoped) {
        Write-NucleusInfo -CommandName check-sh 'no shell scripts to check (scoped mode).'
        exit 0
      }
      $Paths = @(git ls-files '*.sh' ':(exclude)vendor/')
    }

    if ($Paths.Count -eq 0) {
      Write-NucleusInfo -CommandName check-sh 'no shell scripts to check.'
      exit 0
    }

    $exitCode = 0
    foreach ($path in $Paths) {
      # --source-path=<script dir> mirrors treefmt.nix's source-path = "SCRIPTDIR":
      # lets shellcheck resolve `# shellcheck source=` directives relative to each script's own directory.
      & $shellcheck.Source -x --source-path="$(Split-Path -Parent $path)" -S style $path
      if ($LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
      }
    }

    if ($exitCode -ne 0) {
      exit $exitCode
    }

    Write-NucleusInfo -CommandName check-sh "shell script check passed for $($Paths.Count) files."
  }
  finally {
    Pop-Location
  }
}

switch ($Action) {
  'packer' {
    Invoke-CheckPacker @Paths -WindowsTemplateOverride $WindowsTemplateOverride -AnnotationCheckOnly:$AnnotationCheckOnly -ValidateOnly:$ValidateOnly
    exit $LASTEXITCODE
  }
  'sh' {
    Invoke-CheckSh @Paths
    exit $LASTEXITCODE
  }
  'pwsh' {
    & (Join-Path $ScriptDir 'check-pwsh.ps1') @Paths
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & (Join-Path $ScriptDir 'check-pwsh-naming.ps1')
    exit $LASTEXITCODE
  }
  'all' {
    $CheckDir = Join-Path $RepoRoot "src/scripts/checks"
    $FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
    $null = $FrameworkDir  # check-suppress:suppression_doc: consumed by check-lib.ps1 at runtime

    . (Join-Path $CheckDir "check-lib.ps1")
    . (Join-Path $CheckDir "check-steps.ps1")

    Read-Argument $Paths
    Test-Prerequisite
    Invoke-StepPipeline
    Format-StepSummary
  }
}
