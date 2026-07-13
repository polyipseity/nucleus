#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Optimize PDF files using Ghostscript with backup/restore.
.DESCRIPTION
  For each PDF file, creates a .bak backup, runs Ghostscript optimization,
  and removes the backup on success or restores it on failure.
.PARAMETER Preset
  Ghostscript PDF settings preset: default, ebook, prepress, printer, screen.
  Default: default.
.PARAMETER RemoveBackup
  Switch. Remove the .bak backup file on success (kept by default).
.PARAMETER File
  One or more PDF file paths to optimize.
.EXAMPLE
  .\gs-pdf-opt.ps1 document.pdf
  .\gs-pdf-opt.ps1 -Preset screen doc1.pdf doc2.pdf
#>
param(
  [Parameter(Position = 0)]
  [string]$Preset = "default",

  [Parameter()]
  [switch]$RemoveBackup,

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]]$File
)

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# Import ghostscript invocation helper.
# Sync-ShellProfile defines Invoke-NucleusGhostscript; define inline as fallback.
# undoc-supp: probe whether function is already defined; Get-Command throws when absent.
if (-not (Get-Command Invoke-NucleusGhostscript -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusGhostscript {
    # undoc-supp: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }
    # undoc-supp: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }
    # undoc-supp: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }
    throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
  }
}

$validPresets = @("default", "ebook", "prepress", "printer", "screen")
if ($validPresets -notcontains $Preset) {
  Write-NucleusError "unknown preset '$Preset'. Valid: $($validPresets -join ', ')"
  exit 1
}

if ($File.Count -eq 0) {
  Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) [[-Preset] <name>] [[-RemoveBackup]] [-File] <path>..."
  Write-NucleusInfo "presets: $($validPresets -join ', ') (default: default)"
  Write-NucleusInfo "options: -RemoveBackup  Remove the .bak backup on success (kept by default)."
  exit 1
}

foreach ($f in $File) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
    Write-NucleusWarning "skipping non-file: $f"
    continue
  }

  $bak = "$f.bak"
  if (Test-Path -LiteralPath $bak) {
    Write-NucleusError "backup already exists, refusing to overwrite: $bak"
    exit 1
  }

  Move-Item -LiteralPath $f -Destination $bak -Force
  try {
    Invoke-NucleusGhostscript @(
      "-sDEVICE=pdfwrite",
      "-dCompatibilityLevel=2.0",
      "-dPDFSETTINGS=/$Preset",
      "-dNOPAUSE", "-dQUIET", "-dBATCH",
      "-sOutputFile=$(Resolve-Path $f -Relative)",
      "$bak"
    )
    if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
    Write-NucleusInfo "optimized: $f (preset: $Preset)"
  } catch {
    Move-Item -LiteralPath $bak -Destination $f -Force
    Write-NucleusError "optimization failed, restored: $f"
    exit 1
  }
}
