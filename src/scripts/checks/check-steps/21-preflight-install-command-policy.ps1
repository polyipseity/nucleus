Register-Step -Number 21 -Name "Preflight InstallCommand policy" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = @()

  # Find all .ps1 files
  $ps1Files = if ($HasArgs) {
    if ($script:PS1_FILES) { $script:PS1_FILES } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName })  # ref: allow-and-deny-lists.instructions.md#B6 — reason: structural invariant
  }

  if ($ps1Files.Count -gt 0) {
    $selMatches = Select-String -Path $ps1Files -Pattern 'Assert-ToolAvailable.*-InstallCommand' -AllMatches
    foreach ($m in $selMatches) {
      $violations += "$($m.Path):$($m.LineNumber) ($($m.Line.Trim()))"
    }
  }

  if ($violations.Count -gt 0) {
    foreach ($v in $violations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
    throw "Preflight InstallCommand policy check failed: $($violations.Count) violation(s) found."
  }

  Write-Output "check: no preflight InstallCommand violations found."
}
