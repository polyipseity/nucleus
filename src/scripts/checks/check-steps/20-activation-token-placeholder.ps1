Register-Step -Number 20 -Name "Activation script token placeholder in comment check" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $actPattern = '^\s*#.*__[A-Z][A-Z_]*__'
  $actViolations = @()

  if ($HasArgs) {
    $actFiles = $PositionalArgs | Where-Object { $_ -like '*.sh' -or $_ -like '*.zsh' }
    if ($actFiles.Count -gt 0) {
      $actViolations += Select-String -Path $actFiles -Pattern $actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
    }
  } else {
    $actFiles = Get-ChildItem -Recurse -Path (Join-Path $r "src\scripts") -Include '*.sh', '*.zsh' | ForEach-Object { $_.FullName }
    $actViolations += Select-String -Path $actFiles -Pattern $actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
  }

  if ($actViolations.Count -gt 0) {
    foreach ($av in ($actViolations | Sort-Object -Unique)) { Write-ErrorMessage $av }
    Write-ErrorMessage "token placeholder strings found in script comments"
    return $false
  }

  Write-Message "no token placeholder strings in script comments."
  return $true
}
