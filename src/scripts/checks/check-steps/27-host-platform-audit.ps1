Register-Step -Id "host-platform-audit" -Number 27 -Name "Host platform audit" -Action {
  param($RepoRoot)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $auditScript = Join-Path $r 'src/scripts/checks/host-platform-audit.sh'

  if (-not (Test-Path -LiteralPath $auditScript)) {
    Write-ErrorMessage "host-platform-audit.sh not found at $auditScript"
    return $false
  }

  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if (-not $bash) {
    Write-ErrorMessage 'host platform audit requires bash'
    return $false
  }

  & $bash.Source $auditScript $r
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage 'host platform audit failed — see VIOLATION lines above'
    return $false
  }

  Write-Message 'host platform audit passed'
  return $true
}
