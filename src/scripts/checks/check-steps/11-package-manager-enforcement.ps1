Register-Step -Id "package-manager-enforcement" -Name "Package manager usage enforcement" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = 0

  # Skip when scoped to files outside this step's scope (no .sh/.ps1/.nix files).
  if ($HasArgs) {
    $hasShellFiles = @($PositionalArgs | Where-Object { $_ -match '\.(sh|ps1|nix)$' }).Count -gt 0
    if (-not $hasShellFiles) {
      Skip-Step -Number (Get-StepNumber) -Name "Package manager usage enforcement" -Reason "no shell files to check"
      return 2
    }
  }

  # Ban bare pip install and npm install -- these bypass the lockfile.
  # uv pip install is allowed. Exclude self-references.
  # ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator/config files contain pip/npm patterns in comments; self-refs are dynamic
  # WHY: in a runspace the step body is [scriptblock]::Create'd text, so $MyInvocation.MyCommand.Name is empty; fall back to the literal filename so the self-file is still excluded
  $selfPs1 = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { '11-package-manager-enforcement.ps1' }
  $selfSh = if ($MyInvocation.MyCommand.Name) { [System.IO.Path]::ChangeExtension($MyInvocation.MyCommand.Name, '.sh') } else { '11-package-manager-enforcement.sh' }
  $excludeNames = @('check.sh', 'check.ps1', 'shell.nix', $selfPs1, $selfSh)

  if ($HasArgs) {
    # WHY: if-statement output is pipeline-enumerated — an empty else branch yields $null, crashing the .Count checks below under StrictMode; the @() wrapper forces an array
    $shFiles = @(if ($Context.ShFiles) { $Context.ShFiles } else { $PositionalArgs | Where-Object { $_ -like '*.sh' } })
    $ps1Files = @(if ($Context.Ps1Files) { $Context.Ps1Files } else { $PositionalArgs | Where-Object { $_ -like '*.ps1' } })
    $nixFiles = @(if ($Context.NixFiles) { $Context.NixFiles } else { $PositionalArgs | Where-Object { $_ -like '*.nix' } })
    $grepFiles = @($shFiles + $ps1Files + $nixFiles | Where-Object {
        $excludeNames -notcontains [System.IO.Path]::GetFileName($_)
      })
  } else {
    $grepFiles = @(
      Get-ChildItem -Recurse -Path (Join-Path $r 'scripts'), (Join-Path $r 'src'), (Join-Path $r 'tests') `
        -Include *.sh, *.ps1, *.nix `
        -Exclude check.sh, check.ps1, shell.nix, $selfPs1, $selfSh `
        | ForEach-Object { $_.FullName }
    )
  }

  if ($grepFiles.Count -gt 0) {
    $pipViolations = Select-String -Path $grepFiles -Pattern '(^|[^a-z])pip install([^-]|$)' `
      | Where-Object { $_.Line -notmatch 'uv pip install' }

    if ($pipViolations) {
      Write-ErrorMessage "bare pip install detected (use uv pip install instead)"
      $violations++
    }

    $npmViolations = Select-String -Path $grepFiles -Pattern '(^|[^a-z])npm install([^-]|$)'

    if ($npmViolations) {
      Write-ErrorMessage "bare npm install detected (use bun or nix instead)"
      $violations++
    }
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
