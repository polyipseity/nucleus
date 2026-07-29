Register-Step -Number 16 -Name "Package manager usage enforcement" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = 0

  # Ban bare pip install and npm install -- these bypass the lockfile.
  # uv pip install is allowed. Exclude self-references.
  $pipViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$r\scripts", "$r\src", "$r\tests" `
      -Include *.sh, *.ps1, *.nix `
      -Exclude check.sh, check.ps1, shell.nix, 16-package-manager-enforcement.ps1 `
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
      -Exclude check.sh, check.ps1, shell.nix, 16-package-manager-enforcement.ps1 `
      | ForEach-Object { $_.FullName }
  ) -Pattern '(^|[^a-z])npm install([^-]|$)'

  if ($npmViolations) {
    Write-ErrorMessage "bare npm install detected (use bun or nix instead)"
    $violations++
  }

  if ($violations -gt 0) {
    return $false
  }

  Write-Message "no package manager violations found."
  return $true
}
