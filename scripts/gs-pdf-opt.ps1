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
.PARAMETER File
  One or more PDF file paths to optimize.
.EXAMPLE
  .\gs-pdf-opt.ps1 document.pdf
  .\gs-pdf-opt.ps1 -Preset screen doc1.pdf doc2.pdf
#>
param(
  [Parameter(Position = 0)]
  [string]$Preset = "default",

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]]$File
)

# Import ghostscript invocation helper.
# Sync-ShellProfile defines Invoke-NucleusGhostscript; define inline as fallback.
if (-not (Get-Command Invoke-NucleusGhostscript -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusGhostscript {
    if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }
    if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }
    if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }
    throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
  }
}

$validPresets = @("default", "ebook", "prepress", "printer", "screen")
if ($validPresets -notcontains $Preset) {
  Write-Error "Unknown preset '$Preset'. Valid: $($validPresets -join ', ')"
  exit 1
}

if ($File.Count -eq 0) {
  Write-Output "Usage: $(Split-Path -Leaf $PSCommandPath) [[-Preset] <name>] [-File] <path>..."
  Write-Output "Presets: $($validPresets -join ', ') (default: default)"
  exit 1
}

foreach ($f in $File) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
    Write-Warning "Skipping non-file: $f"
    continue
  }

  $bak = "$f.bak"
  if (Test-Path -LiteralPath $bak) {
    Write-Error "Backup already exists, refusing to overwrite: $bak"
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
    Remove-Item -LiteralPath $bak -Force
    Write-Output "Optimized: $f (preset: $Preset)"
  } catch {
    Move-Item -LiteralPath $bak -Destination $f -Force
    Write-Error "Optimization failed, restored: $f"
    exit 1
  }
}
