# modules/windows/resolve-executable.ps1 — Managed executable resolver.
#
# Ensures Windows apply scripts use deterministic executable resolution without
# relying on PATH ordering drift.

function Resolve-Executable {
  <#
  .SYNOPSIS
    Returns the first candidate path that exists on disk.

  .DESCRIPTION
    Iterates $CandidatePaths in order and returns the first path that resolves
    via Test-Path.  Used to locate managed executables (sops, age, gpg) that
    may be installed in different locations depending on how WinGet, Scoop, or a
    manual bootstrap placed them.

  .PARAMETER CandidatePaths
    Ordered list of absolute or relative paths to test.

  .PARAMETER Name
    Display name of the executable, used in the error message when none of the
    candidates are found.

  .OUTPUTS
    [string]  Absolute path of the first candidate that exists.

  .EXAMPLE
    Resolve-Executable -Name 'sops' -CandidatePaths @(
      (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\sops\sops.exe'),
      'C:\ProgramData\scoop\shims\sops.exe'
    )
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CandidatePaths,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  foreach ($candidatePath in $CandidatePaths) {
    if ($candidatePath -and (Test-Path -Path $candidatePath)) {
      return $candidatePath
    }
  }

  throw "Unable to resolve managed executable path for '$Name'."
}
