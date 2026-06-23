function Resolve-Executable {
  <#
  .SYNOPSIS
    Returns the first candidate path that exists on disk.
  .PARAMETER CandidatePaths
    Ordered list of absolute or relative paths to test.
  .PARAMETER Name
    Display name of the executable, used in the error message.
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
