<#
.SYNOPSIS
  Health check for Windows archiving ecosystem (7-Zip CLI + application).

.DESCRIPTION
  Verifies 7z CLI is available in PATH and functional, and checks that the
  7-Zip application is installed. Reports warnings for missing components so
  operators can diagnose archive-handling issues early.

  This is a post-DSC health check and does not attempt to repair or auto-install
  missing components; its purpose is visibility and early failure detection.

.OUTPUTS
  [bool]. Returns `$true` when both the 7z CLI and 7-Zip app checks pass,
  otherwise `$false`. Also writes status and warning messages.

.EXAMPLE
  # Run archiving stack health check:
  Test-ArchivingStack
#>
function Test-ArchivingStack {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $healthCheckPassed = $true

  # Check: 7z CLI is available in PATH and responds to --help.
  Write-Output "archiving-stack: checking 7z CLI availability..."
  $sevenZipExe = Get-Command -Name "7z.exe" -ErrorAction SilentlyContinue
  if ($null -eq $sevenZipExe) {
    Write-Error "archiving-stack: warning — 7z.exe not found in PATH; archive extraction may fail." -ErrorAction Continue
    $healthCheckPassed = $false
  }
  else {
    try {
      & $sevenZipExe.Source --help | Out-Null
      Write-Error "archiving-stack: archiving stack healthy — 7z CLI available and functional." -ErrorAction Continue
    }
    catch {
      Write-Error "archiving-stack: warning — 7z.exe exists but --help failed: $_" -ErrorAction Continue
      $healthCheckPassed = $false
    }
  }

  # Check: 7-Zip application is installed in Program Files.
  Write-Output "archiving-stack: checking 7-Zip application installation..."
  $sevenZipAppPath = Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip"
  if (-not (Test-Path -Path $sevenZipAppPath)) {
    Write-Error "archiving-stack: warning — 7-Zip not found in $env:ProgramFiles; GUI archive handler may be unavailable." -ErrorAction Continue
    $healthCheckPassed = $false
  }
  else {
    Write-Error "archiving-stack: archiving stack healthy — 7-Zip application found." -ErrorAction Continue
  }

  if (-not $healthCheckPassed) {
    Write-Error "archiving-stack: archiving stack health check completed with warnings. See messages above." -ErrorAction Continue
  }
  else {
    Write-Error "archiving-stack: archiving stack health check passed." -ErrorAction Continue
  }

  return $healthCheckPassed
}

# Export function so it can be dot-sourced and invoked.
Export-ModuleMember -Function @("Test-ArchivingStack")
