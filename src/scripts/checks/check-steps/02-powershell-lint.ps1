Register-Step -Id "powershell-lint" -Number 2 -Name "PowerShell lint" -Action {
  param($HasArgs, $RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $ps1Files = $script:PS1_FILES
  if (-not $ps1Files) { $ps1Files = @() }
  if ($ps1Files.Count -gt 0) {
    & "$r\scripts\check-pwsh.ps1" -Settings "$r\scripts\PSScriptAnalyzerSettings.check.psd1" -Scoped -Paths $ps1Files
  } elseif (-not $HasArgs) {
    & "$r\scripts\check-pwsh.ps1" -Settings "$r\scripts\PSScriptAnalyzerSettings.check.psd1"
  } else {
    Write-Message "skipping (no PowerShell scripts to check)."
    return $true
  }

  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "PowerShell lint failed."
    return $false
  }
  Write-Message "PowerShell lint passed."
  return $true
}
