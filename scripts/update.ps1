<#
.SYNOPSIS
  Runs the consolidated Windows update workflow.

.DESCRIPTION
  Executes the native Windows update sequence in one command:
    1. flake input updates (when nix is available)
    2. SOPS recipient rewrap for managed secret files

  Uses the NUCLEUS_REPO_ROOT environment variable to locate the repository
  root; falls back to the parent of the script directory.

.PARAMETER NoFlake
  Do not run nix flake update (default: $false).

.PARAMETER NoBrew
  Do not run Homebrew update/upgrade (macOS only; ignored on Windows) (default: $false).

.PARAMETER NoSops
  Do not run sops updatekeys (default: $false).

.EXAMPLE
  .\update.ps1

.EXAMPLE
  .\update.ps1 -NoFlake

.EXAMPLE
  .\update.ps1 -NoFlake -NoSops

.NOTES
  Environment variables: NUCLEUS_NO_FLAKE, NUCLEUS_NO_BREW, NUCLEUS_NO_SOPS, NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [switch]$NoFlake = $(if ($env:NUCLEUS_NO_FLAKE -eq 'true') { $true } else { $false }),
  [switch]$NoBrew = $(if ($env:NUCLEUS_NO_BREW -eq 'true') { $true } else { $false }),
  [switch]$NoSops = $(if ($env:NUCLEUS_NO_SOPS -eq 'true') { $true } else { $false }),
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

# macOS-only parameter; accepted for interface compatibility.
$NoBrew > $null

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path }

# check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
if (-not $NoFlake -and (Get-Command -Name 'nix.exe' -ErrorAction SilentlyContinue)) {
  $flakeOutput = & nix.exe --option warn-dirty false flake update --flake (Join-Path -Path $repoRoot -ChildPath 'src') 2>&1
  if ($LASTEXITCODE -ne 0) {
    $joined = ($flakeOutput | Out-String)
    if ($joined -match 'API rate limit exceeded|unable to download|HTTP error 403') {
      Write-NucleusWarning 'flake update skipped due to transient fetch/rate-limit error.'
    }
    else {
      throw 'nucleus: nix flake update failed.'
    }
  }
}

# check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
if (-not $NoSops -and -not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
  throw 'nucleus: sops.exe is required for update secret rewrap step.'
}

$sopsConfig = Join-Path -Path $repoRoot -ChildPath '.sops.yaml'

$secretFiles = @(
  (Join-Path -Path $repoRoot -ChildPath 'src\secrets\gpg-personal.yml'),
  (Join-Path -Path $repoRoot -ChildPath 'src\secrets\ssh-personal.yml')
)

if (-not $NoSops) {
foreach ($secretFile in $secretFiles) {
  & sops --config $sopsConfig updatekeys --yes $secretFile
  if ($LASTEXITCODE -ne 0) {
    throw "nucleus: failed to rewrap secret file '$secretFile'."
  }
}

  $usersSecretsDir = Join-Path -Path $repoRoot -ChildPath 'src\secrets\users'
  if (Test-Path -Path $usersSecretsDir) {
    Get-ChildItem -Path $usersSecretsDir -Filter '*.yml' -File | ForEach-Object {
      & sops --config $sopsConfig updatekeys --yes $_.FullName
      if ($LASTEXITCODE -ne 0) {
        throw "nucleus: failed to rewrap per-user secret file '$($_.FullName)'."
      }
    }
  }

  $wallpaperList = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'src\users') -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
  foreach ($encryptedWallpaper in $wallpaperList) {
    & sops --config $sopsConfig updatekeys --yes $encryptedWallpaper.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "nucleus: failed to rewrap wallpaper blob '$($encryptedWallpaper.FullName)'."
    }
  }

  # Close if (-not $WithoutSops).
}

Write-NucleusInfo "$($PSStyle.Foreground.Green)update workflow completed$($PSStyle.Reset)"
