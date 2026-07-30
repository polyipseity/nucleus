Register-Step -Number 1 -Name "Code formatting and linting (treefmt equivalent)" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $yamlFiles = @()
  if ($HasArgs) {
    $yamlFiles = $PositionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
  } else {
    $yamlFiles = if ($script:CachedYamlFiles) {
      $script:CachedYamlFiles | Where-Object { $_.FullName -notmatch '[/\\]secrets[/\\]' } | ForEach-Object { $_.FullName }
    } else {
      Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' |
        Where-Object { $_.FullName -notmatch '[/\]vendor[/\]' -and $_.FullName -notmatch '[/\]secrets[/\]' } |  # ref: EXCLUDE-LISTS.md#B2 — reason: structural invariants
        Sort-Object FullName | ForEach-Object { $_.FullName }
    }
  }

  if ($yamlFiles.Count -gt 0) {
    $ylExit = 0
    foreach ($yf in $yamlFiles) {
      yamllint $yf 2>&1 | ForEach-Object { Write-Output "check: $_" }
      if ($LASTEXITCODE -ne 0) { $ylExit = $LASTEXITCODE }
    }
    if ($ylExit -ne 0) {
      Write-ErrorMessage "yamllint found issues in YAML files."
      return $false
    }
    Write-Message "yamllint passed."
  } else {
    Write-Message "skipping (no YAML files to check)."
  }
  return $true
}
