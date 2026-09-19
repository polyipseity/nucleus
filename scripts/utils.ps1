#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Grouped nucleus user utilities.
.DESCRIPTION
  Currently provides two subcommands:
  - optimize-pdf: optimize PDF files using Ghostscript with backup/restore.
  - strip-metadata: strip file metadata with mat2/exiftool. PDF and legacy
    OLE2 files are skipped with a warning. Inputs that cannot be processed are
    listed at the end of the run; with -Dialog that list is shown in a modal
    popup.
.PARAMETER Action
  The subcommand to run: optimize-pdf, strip-metadata.
.PARAMETER Preset
  Ghostscript PDF settings preset: default, ebook, prepress, printer, screen.
  Default: default. Maps to the optimize-pdf --preset option.
.PARAMETER RemoveBackup
  Switch. Remove the .bak backup file on success (kept by default). Maps to
  the optimize-pdf --rm-bak and strip-metadata --rm-bak options.
.PARAMETER Dialog
  Switch (strip-metadata only). Show one modal popup after the run listing
  every input that was not processed. Needed by GUI callers: the context-menu
  verb runs with -WindowStyle Hidden, which discards stdout and stderr, so a
  modal dialog is the only feedback the user cannot miss.
.PARAMETER File
  One or more file paths to process.
.PARAMETER Help
  Show detailed help.
.EXAMPLE
  .\utils.ps1 optimize-pdf document.pdf
  .\utils.ps1 strip-metadata report.docx
  .\utils.ps1 strip-metadata -Dialog report.docx
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

  [Parameter()]
  [switch]$Dialog,

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]]$File,

  [Alias("h")]
  [switch]$Help
)

# check-suppress:suppression_doc: parameters are consumed via $PSBoundParameters in subcommand dispatch below
$null = $PSBoundParameters

$ErrorActionPreference = 'Stop'

# Show-NucleusNotification — Display a Windows toast notification if BurntToast
# is available; fall back to System.Windows.Forms.MessageBox.
# Args: title, message.
function Show-NucleusNotification {
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- notification is best-effort; all errors intentionally swallowed
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
  param([string]$Title, [string]$Message)
  # check-suppress:suppression_doc: BurntToast module is optional — fall back to MessageBox.
  if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
    try {
      New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
    } catch {
      # check-suppress:suppression_doc: notification is best-effort; swallow all errors.
    }
  } else {
    try {
      [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') > $null
      [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Information') > $null
    } catch {
      # check-suppress:suppression_doc: notification is best-effort; swallow all errors.
    }
  }
}

# Show-NucleusPopup — Display a modal dialog that stays on screen until it is
# dismissed. Unlike Show-NucleusNotification this never degrades to a toast: the
# caller passes -Dialog precisely because nothing else is visible.
# Args: title, message.
function Show-NucleusPopup {
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- the dialog is best-effort; the run already reported the same list to stderr
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
  param([string]$Title, [string]$Message)
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Warning') > $null
  } catch {
    # check-suppress:suppression_doc: dialog is best-effort; swallow all errors.
  }
}

# ConvertTo-NucleusStripMetadataReport — Build the -Dialog popup body.
# Args: processed count, total count, "<reason>|<path>" entries for the inputs
# that were not processed.
# WHY: the list is capped — a message box has no scrollbar, so an unbounded list
# would push the buttons off screen instead of showing the tail.
# WHY: ASCII bullet, separator, and ellipsis only — Windows PowerShell 5.1
# decodes a BOM-less .ps1 as ANSI, so a non-ASCII glyph would reach the popup as
# mojibake.
function ConvertTo-NucleusStripMetadataReport {
  param(
    [int]$Processed,
    [int]$Total,
    [string[]]$NotProcessed
  )
  $max = 10
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("Stripped metadata from $Processed of $Total file(s).")
  $lines.Add('')
  $lines.Add("Not processed ($($NotProcessed.Count)):")
  for ($i = 0; $i -lt $NotProcessed.Count; $i++) {
    if ($i -ge $max) {
      $lines.Add("... and $($NotProcessed.Count - $i) more.")
      break
    }
    $parts = $NotProcessed[$i] -split '\|', 2
    $lines.Add("- $(Split-Path -Leaf $parts[1]) - $($parts[0])")
  }
  return ($lines -join [Environment]::NewLine)
}

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
      Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) strip-metadata [[-RemoveBackup]] [-Dialog] [-File] <path>..."
      Write-NucleusInfo "options: -RemoveBackup  Remove the .bak backup on success (kept by default)."
      Write-NucleusInfo "options: -Dialog  Show one popup listing every input that was not processed."
      exit 1
    }

    # Every input that was not processed, as "<reason>|<path>", collected across
    # the whole run: -Dialog reports them together, because one hidden host
    # cannot show anything per file.
    $notProcessed = [System.Collections.Generic.List[string]]::new()
    $processed = 0
    $failed = 0

    foreach ($f in $File) {
      if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Write-NucleusWarning "skipping non-file: $f"
        $notProcessed.Add("not a file|$f")
        continue
      }

      $bak = "$f.bak"
      if (Test-Path -LiteralPath $bak) {
        # check-suppress:suppression_doc: keep going after a refused input; the failure is recorded and reported at the end.
        Write-NucleusError "backup already exists, refusing to overwrite: $bak" -ErrorAction 'Continue'
        $notProcessed.Add("a .bak backup already exists|$f")
        $failed++
        continue
      }

      $ext = [System.IO.Path]::GetExtension($f).ToLower()
      if ($ext -eq '.pdf') {
        Write-NucleusWarning "skipping PDF (strip-metadata does not support PDF files): $f"
        $notProcessed.Add("PDF files are not supported|$f")
        if (-not $Dialog) {
          Show-NucleusNotification -Title 'strip metadata' -Message "Skipped PDF (not supported): $f"
        }
        continue
      }
      if ($ext -in @('.docx', '.xlsx', '.pptx')) {
        # OOXML: use mat2 for comprehensive metadata stripping.
        # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
        if (-not (Get-Command mat2 -ErrorAction SilentlyContinue)) {
          Write-NucleusWarning "mat2 not found, cannot strip OOXML metadata: $f"
          $notProcessed.Add("mat2 is not installed|$f")
          continue
        }
        Copy-Item -LiteralPath $f -Destination $bak -Force
        try {
          & mat2 --inplace $f
          # WHY: thrown rather than exiting so the remaining inputs are still attempted.
          if ($LASTEXITCODE -ne 0) { throw "mat2 exited with $LASTEXITCODE" }
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          $processed++
          Write-NucleusInfo "stripped metadata: $f"
          Show-NucleusNotification -Title 'strip metadata' -Message "Stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          # check-suppress:suppression_doc: keep going after a failed input; the failure is recorded and reported at the end.
          Write-NucleusError "metadata stripping failed, restored: $f" -ErrorAction 'Continue'
          $notProcessed.Add("metadata stripping failed, original restored|$f")
          $failed++
        }
      } elseif ($ext -in @('.doc', '.xls', '.ppt')) {
        # Legacy OLE2: neither mat2 nor exiftool can write these formats.
        Write-NucleusWarning "skipping legacy OLE2 (no CLI tool can write this format): $f"
        $notProcessed.Add("legacy OLE2 is not supported|$f")
        if (-not $Dialog) {
          Show-NucleusNotification -Title 'strip metadata' -Message "Skipped legacy OLE2 (unsupported format): $f"
        }
      } else {
        # Other formats: use exiftool.
        # WHY: backup first, then in-place strip on the original — .bak holds
        # the untouched original, so an interrupt leaves either the original or
        # the stripped file, never a half-written one.
        Copy-Item -LiteralPath $f -Destination $bak -Force
        try {
          Invoke-NucleusExifTool @(
            "-all=",
            "-overwrite_original",
            $f
          )
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          $processed++
          Write-NucleusInfo "stripped metadata: $f"
          Show-NucleusNotification -Title 'strip metadata' -Message "Stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          # check-suppress:suppression_doc: keep going after a failed input; the failure is recorded and reported at the end.
          Write-NucleusError "metadata stripping failed, restored: $f" -ErrorAction 'Continue'
          $notProcessed.Add("metadata stripping failed, original restored|$f")
          $failed++
        }
      }
    }

    # Report once, after every input has been attempted: -Dialog exists because
    # the GUI caller has no terminal to read.
    if ($Dialog -and $notProcessed.Count -gt 0) {
      $reportArgs = @{
        Processed = $processed
        Total = $File.Count
        NotProcessed = $notProcessed.ToArray()
      }
      Show-NucleusPopup -Title 'strip metadata' -Message (ConvertTo-NucleusStripMetadataReport @reportArgs)
    }

    if ($failed -gt 0) { exit 1 }
  }
}
