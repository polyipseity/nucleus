Register-Step -Id "yaml-structural" -Name "YAML structural validation" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $yamlErrors = 0
  $yamlFiles = @()

  if ($HasArgs) {
    $yamlFiles = $PositionalArgs | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' }
  } else {
    $yamlFiles = if ($Context.CachedYamlFiles) {
      $Context.CachedYamlFiles |
        Where-Object { $_ } |
        ForEach-Object { $_ }
    } else {
      Get-ChildItem -Recurse -Path $r -Include '*.yml', '*.yaml' |
        Where-Object { $_.FullName -notmatch '[/\\]vendor[/\\]' } |  # ref: allow-and-deny-lists.instructions.md#B4 -- structural invariant; gitignore filter applied on top
        Sort-Object FullName | Select-GitIgnored | ForEach-Object { $_ }
    }
  }

  foreach ($yf in $yamlFiles) {
    try {
      $content = Get-Content $yf -Raw -ErrorAction Stop
      $null = $content | ConvertFrom-Yaml -ErrorAction Stop  # check-suppress:suppression_doc: parsed object discarded; -ErrorAction Stop surfaces invalid YAML via throw
    } catch {
      Write-ErrorMessage "$yf : invalid YAML"
      $yamlErrors++
    }
  }

  if ($yamlErrors -gt 0) {
    Write-ErrorMessage "YAML structural validation failed with $yamlErrors error(s)"
    return $false
  }

  if ($yamlFiles.Count -eq 0) {
    Skip-Step -Number (Get-StepNumber) -Name "YAML structural validation" -Reason "no YAML files to check"
    return 2
  }

  Write-Message "YAML structural validation passed."
  return $true
}
