Register-Step -Id "powershell-lint" -Name "PowerShell syntax" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $ps1Files = $Context.Ps1Files
  if (-not $ps1Files) { $ps1Files = @() }
  & "$r\scripts\check.ps1" pwsh
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "PowerShell check failed."
    return $false
  }

  Write-Message "PowerShell syntax check passed."
  return $true
}
