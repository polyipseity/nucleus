Register-Step -Id "legacy-token-syntax" -Number 23 -Name "Legacy token syntax gate" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = @()
  $selfLeaf = Split-Path -Leaf $PSCommandPath

  # Token convention scope: production code under src/ and scripts/ with code
  # extensions — same scope as the Pester gate
  # (tests/hosts/Windows/embedded-content/no-legacy-token-syntax.Tests.ps1).
  # .md prose and tests/ fixtures are excluded by scope (they cite the legacy form).
  $extensions = @('.ps1', '.sh', '.zsh', '.nix', '.yml')

  $scanFiles = if ($HasArgs) {
    @($PositionalArgs | Where-Object {
      (($_ -like 'src/*') -or ($_ -like 'scripts/*')) -and
      ($extensions -contains [System.IO.Path]::GetExtension($_)) -and
      ((Split-Path -Leaf $_) -ne $selfLeaf)
    })
  } else {
    @(Get-ChildItem -Path (Join-Path $r 'src'), (Join-Path $r 'scripts') -Recurse -File |
      Where-Object { $extensions -contains $_.Extension } |
      Where-Object { $_.Name -ne $selfLeaf } |
      ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#C6 -- structural invariant; gitignore filter applied on top
  }

  foreach ($file in $scanFiles) {
    $content = Get-Content -Raw -Path $file
    $lineNo = 0
    foreach ($line in ($content -split "`r?`n")) {
      $lineNo++
      if ($line -match '\{\{[A-Za-z_]') {
        $violations += "${file}:${lineNo}: legacy token placeholder syntax (use double-underscore UPPER_SNAKE placeholders)"
      }
    }
  }

  if ($violations.Count -gt 0) {
    foreach ($v in $violations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Use double-underscore UPPER_SNAKE placeholders — see .agents/instructions/embedded-content.instructions.md section 4."
    throw "Legacy token syntax check failed: $($violations.Count) violation(s) found."
  }

  Write-Output "check: no legacy token placeholder syntax found."
}
