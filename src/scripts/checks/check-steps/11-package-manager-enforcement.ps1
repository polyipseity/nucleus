Register-Step -Id "package-manager-enforcement" -Number 11 -Name "Package manager usage enforcement" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = 0

  # Skip when scoped to files outside this step's scope (no .sh/.ps1/.nix files).
  if ($HasArgs) {
    $hasShellFiles = @($PositionalArgs | Where-Object { $_ -match '\.(sh|ps1|nix)$' }).Count -gt 0
    if (-not $hasShellFiles) {
      Write-Message "==== 11: Package manager usage enforcement ==== SKIPPED (no shell files to check)"
      return 2
    }
  }

  # Ban bare pip install and npm install -- these bypass the lockfile.
  # uv pip install is allowed. Exclude self-references.
  # ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator/config files contain pip/npm patterns in comments; self-refs are dynamic
  $selfPs1 = $MyInvocation.MyCommand.Name
  $selfSh = [System.IO.Path]::ChangeExtension($selfPs1, '.sh')
  $pipViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$r\scripts", "$r\src", "$r\tests" `
      -Include *.sh, *.ps1, *.nix `
      -Exclude check.sh, check.ps1, shell.nix, $selfPs1, $selfSh `
      | ForEach-Object { $_.FullName }
  ) -Pattern '(^|[^a-z])pip install([^-]|$)' `
    | Where-Object { $_.Line -notmatch 'uv pip install' }

  if ($pipViolations) {
    Write-ErrorMessage "bare pip install detected (use uv pip install instead)"
    $violations++
  }

  $npmViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$r\scripts", "$r\src", "$r\tests" `
      -Include *.sh, *.ps1, *.nix `
      -Exclude check.sh, check.ps1, shell.nix, $selfPs1, $selfSh `
      | ForEach-Object { $_.FullName }
  ) -Pattern '(^|[^a-z])npm install([^-]|$)'

  if ($npmViolations) {
    Write-ErrorMessage "bare npm install detected (use bun or nix instead)"
    $violations++
  }

  # Self-pruning: verify excluded files still justify their exclusion (A1)
  foreach ($ef in @('check.sh', 'check.ps1', 'shell.nix')) {
    $efPath = Join-Path $r $ef
    if ((Test-Path $efPath) -and -not (Select-String -LiteralPath $efPath -Pattern '(pip install|npm install)' -Quiet)) {
      Write-ErrorMessage "stale exclusion: '$ef' no longer contains pip/npm install patterns — remove from -Exclude list"
      $violations++
    }
  }

  if ($violations -gt 0) {
    return $false
  }

  Write-Message "no package manager violations found."
  return $true
}
