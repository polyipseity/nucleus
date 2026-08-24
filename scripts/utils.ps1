#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Grouped nucleus user utilities.
.DESCRIPTION
  Currently provides the optimize-pdf subcommand: optimize PDF files using
  Ghostscript with backup/restore. The optimize-pdf subcommand's --preset and
  --rm-bak options map to the -Preset and -RemoveBackup PowerShell parameters
  below; input files map to -File.
.PARAMETER Action
  The subcommand to run: optimize-pdf.
.PARAMETER Preset
  Ghostscript PDF settings preset: default, ebook, prepress, printer, screen.
  Default: default. Maps to the optimize-pdf --preset option.
.PARAMETER RemoveBackup
  Switch. Remove the .bak backup file on success (kept by default). Maps to
  the optimize-pdf --rm-bak option.
.PARAMETER File
  One or more PDF file paths to optimize.
.PARAMETER Help
  Show detailed help.
.EXAMPLE
  .\utils.ps1 optimize-pdf document.pdf
  .\utils.ps1 optimize-pdf -Preset screen doc1.pdf doc2.pdf
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('optimize-pdf')]
  [string]$Action,

  [Parameter()]
  [string]$Preset = "default",

  [Parameter()]
  [switch]$RemoveBackup,

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]]$File,

  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing subcommand (optimize-pdf)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# Import ghostscript invocation helper.
# Sync-ShellProfile defines Invoke-NucleusGhostscript; define inline as fallback.
# check-suppress:suppression_doc: probe whether function is already defined; Get-Command throws when absent.
if (-not (Get-Command Invoke-NucleusGhostscript -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusGhostscript {
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }
    throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
  }
}

switch ($Action) {
  'optimize-pdf' {
    $validPresets = @("default", "ebook", "prepress", "printer", "screen")
    if ($validPresets -notcontains $Preset) {
      Write-NucleusError "unknown preset '$Preset'. Valid: $($validPresets -join ', ')"
      exit 1
    }

    if ($File.Count -eq 0) {
      Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) optimize-pdf [[-Preset] <name>] [[-RemoveBackup]] [-File] <path>..."
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
  }
}
