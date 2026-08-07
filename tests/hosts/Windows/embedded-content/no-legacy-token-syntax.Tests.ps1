<#
.SYNOPSIS
    Token-convention gate: no legacy {{TOKEN}} syntax in production code and
    config files under src/ and scripts/.
.DESCRIPTION
    Enforces the embedded-content policy token convention (__UPPER_SNAKE__
    only) with a greppable, deterministic check.  Scans production locations
    (src/, scripts/) with code extensions (.ps1, .sh, .zsh, .nix, .yml), the
    same scope as the plan's verification-matrix grep.

    Excluded by scope, with documented reasons:
    - .md prose: instruction docs cite {{TOKEN}} as the prohibited form
      (embedded-content.instructions.md) and AI prompt files use
      {{LANE_SCOPE}} as a prompt-harness variable
      (src/users/default/agents/prompts/maintain.prompt.md).
    - tests/: Pester assertions and Nix test messages reference {{TOKEN}} as
      the negative-assertion target by design.

    The grep pattern \{\{[A-Za-z_] excludes GitHub Actions ${{ }} expressions
    ({{ followed by whitespace).

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/embedded-content/no-legacy-token-syntax.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $ScanDirs = @(
    (Join-Path $RepoRoot "src"),
    (Join-Path $RepoRoot "scripts")
  )
  $Extensions = @('.ps1', '.sh', '.zsh', '.nix', '.yml')

  function Get-ProductionCodeFileList {
    return @(Get-ChildItem -Path $ScanDirs -Recurse -File | Where-Object { $_.Extension -in $Extensions })
  }
}

Describe "No legacy {{TOKEN}} syntax in production code files" {
  It "PowerShell files under src/ and scripts/ contain no {{ placeholders" {
    $violations = @()
    foreach ($file in Get-ProductionCodeFileList) {
      if ($file.Extension -ne '.ps1') { continue }
      $content = Get-Content -Raw -Path $file.FullName
      if ([regex]::IsMatch($content, '\{\{[A-Za-z_]')) { $violations += $file.FullName }
    }
    $violations | Should -BeNullOrEmpty
  }

  It "shell files under src/ and scripts/ contain no {{ placeholders" {
    $violations = @()
    foreach ($file in Get-ProductionCodeFileList) {
      if ($file.Extension -notin @('.sh', '.zsh')) { continue }
      $content = Get-Content -Raw -Path $file.FullName
      if ([regex]::IsMatch($content, '\{\{[A-Za-z_]')) { $violations += $file.FullName }
    }
    $violations | Should -BeNullOrEmpty
  }

  It "Nix and YAML files under src/ and scripts/ contain no {{ placeholders" {
    $violations = @()
    foreach ($file in Get-ProductionCodeFileList) {
      if ($file.Extension -notin @('.nix', '.yml')) { continue }
      $content = Get-Content -Raw -Path $file.FullName
      if ([regex]::IsMatch($content, '\{\{[A-Za-z_]')) { $violations += $file.FullName }
    }
    $violations | Should -BeNullOrEmpty
  }
}
