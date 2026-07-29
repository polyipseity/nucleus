Register-Step -Number 3 -Name "Packer template validation" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $pkrFiles = if ($script:PKR_FILES) { $script:PKR_FILES } else { @() }
  if ($pkrFiles.Count -gt 0) {
    & "$r\scripts\check-packer.ps1" $pkrFiles
  } elseif (-not $HasArgs) {
    & "$r\scripts\check-packer.ps1"
  } else {
    Write-Message "skipping (no Packer templates to check)."
    return $true
  }

  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "Packer template validation failed."
    return $false
  }
  Write-Message "Packer template validation passed."
  return $true
}
