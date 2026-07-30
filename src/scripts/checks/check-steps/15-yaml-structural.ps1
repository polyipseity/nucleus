Register-Step -Number 15 -Name "YAML structural validation" -Action {
  param($HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  $null = $WaveTmpDir # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — positional binding requires all 4 params

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $yamlErrors = 0
  $yamlFiles = @()

  if ($HasArgs) {
    $yamlFiles = $PositionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
  } else {
    $yamlFiles = if ($script:CachedYamlFiles) {
      $script:CachedYamlFiles |
        Where-Object { $_.FullName -notmatch '[/\\]secrets[/\\]' } |
        ForEach-Object { $_.FullName }
    } else {
      Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' -and $_.FullName -notmatch '[/\\]secrets[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B4 — reason: structural invariants
        Sort-Object FullName | ForEach-Object { $_.FullName }
    }
  }

  foreach ($yf in $yamlFiles) {
    try {
      $content = Get-Content $yf -Raw -ErrorAction Stop
      $null = $content | ConvertFrom-Yaml -ErrorAction Stop
    } catch {
      Write-ErrorMessage "$yf : invalid YAML"
      $yamlErrors++
    }
  }

  if ($yamlErrors -gt 0) {
    Write-ErrorMessage "YAML structural validation failed with $yamlErrors error(s)"
    return $false
  }

  Write-Message "YAML structural validation passed."
  return $true
}
