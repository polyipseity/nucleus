# check.ps1: consolidated repository validation script (Windows).
#
# Thin orchestrator: sources check-lib.ps1 for the framework and check-steps.ps1 for
# step registration, then runs the pipeline.
#
# Arguments:
#   -Action <all|packer|sh|pwsh>  Which check to run (default: all).
#                     all    Run every check via the step pipeline.
#                     packer Run the Packer template validation.
#                     sh     Run the shell script lint (ShellCheck).
#                     pwsh   Run check-pwsh.ps1.
#   --full           Run all checks including whole-repo checks (default).
#   --scoped         Run only path-scopable checks.
#   --fail-fast      Exit immediately on first failure.
#   --no-fail-fast   Accumulate all failures (default).
#   --online         Run online determinism checks.
#   --verbose        Stream all step output (default: headers + summaries only).
#   --verbose=<ids>  Stream only the specified comma-separated step IDs.
#   --no-verbose     Suppress step output streaming (default).
#   --only-steps=<ids>  Run only steps with the given comma-separated IDs.
#   --list-steps     Print registered step IDs and exit.
#   (paths)          Files to check; restricts --scoped to matching files.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.

#Requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$ScriptDir = $PSScriptRoot

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

# Manual argument parsing: accepts PowerShell-style and POSIX-style flags.
# Bare flags mean no action word was given (B10/E4).
$Action = 'all'
$Paths = @()
$WindowsTemplateOverride = ''
$AnnotationCheckOnly = $false
$ValidateOnly = $false
$ListSteps = $false

$_ua = @($args)
$i = 0
# First token may be an action word.
if ($_ua.Count -gt 0 -and $_ua[0] -in @('all', 'packer', 'sh', 'pwsh', 'nix', 'yaml')) {
  $Action = [string]$_ua[0]
  $i = 1
}
while ($i -lt $_ua.Count) {
  $a = [string]$_ua[$i]
  switch -Regex ($a) {
    '^(-h|--help|-Help)$' {
      if ($Action -eq 'all') { $Action = 'all'; $ListSteps = $false } # handled by pipeline/help
      # Let pipeline/subcommand handle help where possible; for --help at top level show usage.
      $Paths += $a; $i++; continue
    }
    '^(-ListSteps|--list-steps)$' { $ListSteps = $true; $i++; continue }
    '^(-WindowsTemplateOverride|--windows-template-override)$' {
      if ($i + 1 -ge $_ua.Count) { throw "nucleus: check: $a requires a value" }
      $WindowsTemplateOverride = [string]$_ua[$i + 1]; $i += 2; continue
    }
    '^--windows-template-override=(.+)$' { $WindowsTemplateOverride = $Matches[1]; $i++; continue }
    '^(-AnnotationCheckOnly|--annotation-check-only)$' { $AnnotationCheckOnly = $true; $i++; continue }
    '^(-ValidateOnly|--validate-only)$' { $ValidateOnly = $true; $i++; continue }
    '^(-Action|--action)$' {
      if ($i + 1 -ge $_ua.Count) { throw "nucleus: check: $a requires a value" }
      $Action = [string]$_ua[$i + 1]; $i += 2; continue
    }
    '^--paths$' { $i++; continue } # consume marker; remaining are paths
    default {
      $Paths += $a
      $i++; continue
    }
  }
}

if ($ListSteps) {
  Set-Location -Path $RepoRoot
  $FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
  $CheckDir = Join-Path $RepoRoot "src/scripts/checks"
  . (Join-Path $CheckDir "check-lib.ps1")
  . (Join-Path $CheckDir "check-steps.ps1")
  foreach ($id in $script:StepIds) { Write-Output $id }
  exit 0
}

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

    # Test seam: point the packer_validate annotation check at a different template file.
    [string]$WindowsTemplateOverride = '',

    [switch]$AnnotationCheckOnly,

    [switch]$ValidateOnly
  )

. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

  Set-Location -Path $RepoRoot

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
    Lint repository shell scripts with ShellCheck.
  .DESCRIPTION
    Discovers tracked *.sh files via git ls-files (excluding vendor/) or accepts explicit
    paths. Flags match src/modules/lib/script-tree.nix: -x -S style.
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
    throw 'shellcheck is required but was not found in PATH (install koalaman.shellcheck via WinGet)'
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
      # --source-path=<script dir> mirrors treefmt.nix's source-path = "SCRIPTDIR", so
      # shellcheck resolves `# shellcheck source=` against each script's own directory.
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

if ($Action -in @('packer', 'sh', 'pwsh')) {
  $subcmdHelp = @($Paths | Where-Object { $_ -in @('-h', '--help', '-Help', 'help') }).Count -gt 0
  if (-not $subcmdHelp) {
    . (Join-Path $RepoRoot "src/scripts/lib/bundle-freshness.ps1")
    Write-BundleFreshnessNotice
  }
}

switch ($Action) {
  'packer' {
    # WHY: filter pipeline flags from Paths: subcommands don't understand them.
    $PackerPaths = @($Paths | Where-Object { $_ -notmatch '^--verbose' -and $_ -ne '--no-verbose' -and $_ -notmatch '^--only-steps' -and $_ -notmatch '^--fail-fast' -and $_ -notmatch '^--no-fail-fast' -and $_ -ne '--scoped' -and $_ -ne '--full' -and $_ -ne '--online' })
    Invoke-CheckPacker @PackerPaths -WindowsTemplateOverride $WindowsTemplateOverride -AnnotationCheckOnly:$AnnotationCheckOnly -ValidateOnly:$ValidateOnly
    exit $LASTEXITCODE
  }
  'sh' {
    $ShPaths = @($Paths | Where-Object { $_ -notmatch '^--verbose' -and $_ -ne '--no-verbose' -and $_ -notmatch '^--only-steps' -and $_ -notmatch '^--fail-fast' -and $_ -notmatch '^--no-fail-fast' -and $_ -ne '--scoped' -and $_ -ne '--full' -and $_ -ne '--online' })
    Invoke-CheckSh @ShPaths
    exit $LASTEXITCODE
  }
  'pwsh' {
    $PwshPaths = @($Paths | Where-Object { $_ -notmatch '^--verbose' -and $_ -ne '--no-verbose' -and $_ -notmatch '^--only-steps' -and $_ -notmatch '^--fail-fast' -and $_ -notmatch '^--no-fail-fast' -and $_ -ne '--scoped' -and $_ -ne '--full' -and $_ -ne '--online' })
    & (Join-Path $ScriptDir '..\src\scripts\checks\check-pwsh.ps1') @PwshPaths
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    exit 0
  }
  default {
    # 'all' and unknown treated as all pipeline run (POSIX behavior: no subcommand = full check)
    $CheckDir = Join-Path $RepoRoot "src/scripts/checks"
    $FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"
    $null = $FrameworkDir  # check-suppress:suppression_doc: consumed by check-lib.ps1 at runtime

    . (Join-Path $CheckDir "check-lib.ps1")
    . (Join-Path $CheckDir "check-steps.ps1")
    . (Join-Path $RepoRoot "src/scripts/lib/bundle-freshness.ps1")

    Read-Argument $Paths
    Test-Prerequisite
    Write-BundleFreshnessNotice
    Invoke-StepPipeline
    Format-StepSummary
  }
}
