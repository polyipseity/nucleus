<#
.SYNOPSIS
  Runs the consolidated Windows update workflow.

.DESCRIPTION
  Executes the native Windows update sequence in one command:
    1. winget package upgrades (when available)
    2. SOPS recipient rewrap for managed secret files

.EXAMPLE
  .\update.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path

if (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue) {
  winget upgrade --all --accept-package-agreements --accept-source-agreements --disable-interactivity
}

if (-not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
  throw 'nucleus: sops.exe is required for update secret rewrap step.'
}

$secretFiles = @(
  (Join-Path -Path $repoRoot -ChildPath 'src\secrets\git-identities.yml'),
  (Join-Path -Path $repoRoot -ChildPath 'src\secrets\gpg-personal.yml'),
  (Join-Path -Path $repoRoot -ChildPath 'src\secrets\ssh-personal.yml')
)

foreach ($secretFile in $secretFiles) {
  & sops updatekeys --yes $secretFile
  if ($LASTEXITCODE -ne 0) {
    throw "nucleus: failed to rewrap secret file '$secretFile'."
  }
}

$wallpaperDir = Join-Path -Path $repoRoot -ChildPath 'src\assets\wallpapers'
if (Test-Path -Path $wallpaperDir) {
  Get-ChildItem -Path $wallpaperDir -Filter '*.sops' -File | ForEach-Object {
    & sops updatekeys --yes $_.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "nucleus: failed to rewrap wallpaper blob '$($_.FullName)'."
    }
  }
}

Write-Output "$($PSStyle.Foreground.Green)nucleus: update workflow completed$($PSStyle.Reset)"
