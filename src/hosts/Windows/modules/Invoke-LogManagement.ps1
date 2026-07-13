<#
.SYNOPSIS
  Log directory helpers and management functions for nucleus services.

.DESCRIPTION
  Provides four functions:
    Get-NucleusLogDir        — user-level log directory (%LOCALAPPDATA%\nucleus\logs)
    Get-NucleusSystemLogDir  — system-level log directory (%ProgramData%\nucleus\logs)
    ConvertTo-SanitizedText  — strips ANSI escapes and control characters from log text
    Invoke-LogRotation       — rotates log files in a directory based on size

.NOTES
  Environment variables:
    (none)    Paths are derived from %LOCALAPPDATA% and %ProgramData%.
  Exit codes:
    0 on success; 1 on error.
#>

function Get-NucleusLogDir {
  <#
  .SYNOPSIS
    Returns the user-level log directory path.
  .DESCRIPTION
    Returns %LOCALAPPDATA%\nucleus\logs. Creates the directory if it does not exist.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  .EXAMPLE
    Get-NucleusLogDir
  #>
  [CmdletBinding()]
  param(
    [switch]$PassThru
  )

  $path = Join-Path -Path $env:LOCALAPPDATA -ChildPath "nucleus\logs"
  if ($PassThru -and -not (Test-Path -LiteralPath $path -PathType Container)) {
    $null = New-Item -Path $path -ItemType Directory -Force
  }
  return $path
}

function Get-NucleusSystemLogDir {
  <#
  .SYNOPSIS
    Returns the system-level log directory path.
  .DESCRIPTION
    Returns %ProgramData%\nucleus\logs. Creates the directory if it does not exist.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  .EXAMPLE
    Get-NucleusSystemLogDir
  #>
  [CmdletBinding()]
  param(
    [switch]$PassThru
  )

  $path = Join-Path -Path $env:ProgramData -ChildPath "nucleus\logs"
  if ($PassThru -and -not (Test-Path -LiteralPath $path -PathType Container)) {
    $null = New-Item -Path $path -ItemType Directory -Force
  }
  return $path
}

function ConvertTo-SanitizedText {
  <#
  .SYNOPSIS
    Strips ANSI escape sequences and control characters from text input.
  .DESCRIPTION
    Reads text from the pipeline or a file and removes ANSI escape sequences
    (colors, cursor movement, OSC sequences), carriage returns, and ASCII
    control characters (except tab and newline).
  .PARAMETER InputObject
    String to sanitize. Accepts pipeline input.
  .EXAMPLE
    "hello\x1b[31mworld" | ConvertTo-SanitizedText
  .EXAMPLE
    Get-Content -Path log.txt | ConvertTo-SanitizedText
  #>
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline)]
    [string]$InputObject
  )

  process {
    if ([string]::IsNullOrEmpty($InputObject)) { return }
    $sanitized = $InputObject -replace '\x1b\[[0-9;]*[a-zA-Z]', ''      # ANSI escapes
    $sanitized = $sanitized -replace '\x1b\][^\x07\x1b]*\x07', ''       # OSC sequences
    $sanitized = $sanitized -replace '\x1b[PX^_].*\x1b\\', ''           # DCS/SOS/PM/APC
    $sanitized = $sanitized -replace '\r', ''                            # carriage returns
    $sanitized = $sanitized -replace '[^\x09\x0A\x20-\x7E\x80-\xFF]', '' # control chars except tab/newline
    Write-Output $sanitized
  }
}

function Invoke-LogRotation {
  <#
  .SYNOPSIS
    Rotates log files in a directory based on size.
  .DESCRIPTION
    Scans for *.log files in the given directory. When a file exceeds MaxSize,
    it is renamed to <name>.N.log (shifting existing archives) up to MaxFiles.
    Rotated files are optionally compressed with gzip.
  .PARAMETER Path
    Directory containing log files to rotate.
  .PARAMETER MaxSize
    Maximum file size in bytes before rotation (default: 10 MB).
  .PARAMETER MaxFiles
    Number of rotated archives to keep (default: 4).
  .PARAMETER Compress
    Whether to compress rotated archives with gzip (default: $true).
  .EXAMPLE
    Invoke-LogRotation -Path "$env:LOCALAPPDATA\nucleus\logs\discord-music-rpc"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [int]$MaxSize = 10000000, # bytes
    [int]$MaxFiles = 4,
    [bool]$Compress = $true
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

  $logFiles = Get-ChildItem -Path $Path -Filter "*.log" -File
  foreach ($file in $logFiles) {
    if ($file.Length -le $MaxSize) { continue }

    $baseName = $file.BaseName
    $dir = $file.DirectoryName

    # Remove the oldest archive if at max
    $oldest = $MaxFiles
    $oldestPath = Join-Path -Path $dir -ChildPath "$baseName.$oldest.log"
    if (Test-Path -LiteralPath $oldestPath -PathType Leaf) {
      Remove-Item -LiteralPath $oldestPath -Force
    }
    if ($Compress) {
      $oldestGz = "$oldestPath.gz"
      if (Test-Path -LiteralPath $oldestGz -PathType Leaf) {
        Remove-Item -LiteralPath $oldestGz -Force
      }
    }

    # Shift existing archives: N → N+1
    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
      $src = Join-Path -Path $dir -ChildPath "$baseName.$i.log"
      $dst = Join-Path -Path $dir -ChildPath "$baseName.$($i + 1).log"
      if (Test-Path -LiteralPath $src -PathType Leaf) {
        Move-Item -LiteralPath $src -Destination $dst -Force
      }
      if ($Compress) {
        $srcGz = "$src.gz"
        $dstGz = "$dst.gz"
        if (Test-Path -LiteralPath $srcGz -PathType Leaf) {
          Move-Item -LiteralPath $srcGz -Destination $dstGz -Force
        }
      }
    }

    # Rename current log → .1.log, optionally compress
    $archivePath = Join-Path -Path $dir -ChildPath "$baseName.1.log"
    Move-Item -LiteralPath $file.FullName -Destination $archivePath -Force

    if ($Compress) {
      $null = & "gzip" @("$archivePath") 2>$null  # undoc-supp: archive may fail to compress if already corrupted or missing; $? checked below
      if (-not $?) {
        Write-Warning "log-rotation: gzip failed for $archivePath; keeping uncompressed."
      }
    }
  }
}
