#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Grouped nucleus user utilities.
.DESCRIPTION
  Currently provides two subcommands:
  - optimize-pdf: optimize PDF files using Ghostscript with backup/restore.
  - strip-metadata: strip file metadata with mat2/exiftool.
.PARAMETER Action
  The subcommand to run: optimize-pdf, strip-metadata.
.PARAMETER Preset
  Ghostscript PDF settings preset: default, ebook, prepress, printer, screen.
  Default: default. Maps to the optimize-pdf --preset option.
.PARAMETER RemoveBackup
  Switch. Remove the .bak backup file on success (kept by default). Maps to
  the optimize-pdf --rm-bak and strip-metadata --rm-bak options.
.PARAMETER File
  One or more file paths to process.
.PARAMETER Help
  Show detailed help.
.EXAMPLE
  .\utils.ps1 optimize-pdf document.pdf
  .\utils.ps1 strip-metadata report.docx
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('optimize-pdf', 'strip-metadata')]
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
  if (-not $Action) { Write-NucleusError "missing subcommand (optimize-pdf or strip-metadata)" }
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

# Import exiftool invocation helper.
# check-suppress:suppression_doc: probe whether function is already defined; Get-Command throws when absent.
if (-not (Get-Command Invoke-NucleusExifTool -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusExifTool {
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command exiftool -ErrorAction SilentlyContinue) { & exiftool @Args; return }
    throw "ExifTool CLI not found. Expected: exiftool"
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

  'strip-metadata' {
    if ($File.Count -eq 0) {
      Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) strip-metadata [[-RemoveBackup]] [-File] <path>..."
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

      $ext = [System.IO.Path]::GetExtension($f).ToLower()
      if ($ext -in @('.docx', '.xlsx', '.pptx')) {
        # OOXML: use mat2 for comprehensive metadata stripping.
        # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
        if (-not (Get-Command mat2 -ErrorAction SilentlyContinue)) {
          Write-NucleusWarning "mat2 not found, cannot strip OOXML metadata: $f"
          continue
        }
        Copy-Item -LiteralPath $f -Destination $bak -Force
        try {
          & mat2 -o $f $bak
          if ($LASTEXITCODE -ne 0) {
            Move-Item -LiteralPath $bak -Destination $f -Force
            Write-NucleusError "metadata stripping failed, restored: $f"
            exit 1
          }
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          Write-NucleusInfo "stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          Write-NucleusError "metadata stripping failed, restored: $f"
          exit 1
        }
      } elseif ($ext -in @('.doc', '.xls', '.ppt')) {
        # Legacy OLE2: neither mat2 nor exiftool can write these formats.
        Write-NucleusWarning "skipping legacy OLE2 (no CLI tool can write this format): $f"
      } else {
        # Other formats: use exiftool.
        Move-Item -LiteralPath $f -Destination $bak -Force
        try {
          Invoke-NucleusExifTool @(
            "-all=",
            "-overwrite_original",
            "-o", (Resolve-Path $f -Relative),
            "$bak"
          )
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          Write-NucleusInfo "stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          Write-NucleusError "metadata stripping failed, restored: $f"
          exit 1
        }
      }
    }
  }
}
