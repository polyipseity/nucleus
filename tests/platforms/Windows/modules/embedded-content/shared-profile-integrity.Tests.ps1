<#
.SYNOPSIS
    Verifies the shared PowerShell profile (src/scripts/shell/profile.ps1)
    remains the single source of truth for both platforms and that every token
    it declares is replaced by every consumer.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Enforces the
    embedded-content policy "shared cross-platform content" and "token
    completeness" rules:

    - Sync-ShellProfile.ps1 (Windows) must read profile.ps1 from disk, not
      embed a literal copy.
    - Every __TOKEN__ in profile.ps1 must be replaced by Sync-ShellProfile's
      -replace chain (Windows render leaves no unreplaced token).
    - Every __TOKEN__ in profile.ps1 must be replaced by pwsh.nix's
      replaceStrings (POSIX render leaves no unreplaced token).

    True byte-equivalence of the rendered profile is not asserted here because
    rendering requires executing Sync-ShellProfile (depends on ManagedPaths and
    $PROFILE); the token-completeness and single-source checks above imply the
    rendered output equals the template modulo substituted token values.

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/embedded-content/shared-profile-integrity.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $ProfilePath = Join-Path $RepoRoot "src\scripts\shell\profile.ps1"
  $SyncShellProfilePath = Join-Path $RepoRoot "src\platforms\Windows\modules\user\Sync-ShellProfile.ps1"
  $PwshNixPath = Join-Path $RepoRoot "src\modules\pwsh.nix"

  # Path variables are read through these closures so PSUseDeclaredVarsMoreThanAssignments
  # sees them used within the BeforeAll scriptblock (It blocks are sibling scopes).
  function Get-ProfileContent { return Get-Content -Raw -Path $ProfilePath }
  function Get-SyncShellProfileContent { return Get-Content -Raw -Path $SyncShellProfilePath }
  function Get-PwshNixContent { return Get-Content -Raw -Path $PwshNixPath }

  function Get-UpperSnakeTokenList([string]$Path) {
    $content = Get-Content -Raw -Path $Path
    return @([regex]::Matches($content, '__[A-Z][A-Z_]*__') | ForEach-Object { $_.Value } | Sort-Object -Unique)
  }
}

Describe "Shared profile single source" {
  It "Sync-ShellProfile reads profile.ps1 from disk" {
    $syncContent = Get-SyncShellProfileContent
    $syncContent | Should -Match ([regex]::Escape("Get-Content -Raw (Join-Path `$PSScriptRoot -ChildPath '..\..\..\..\scripts\shell\profile.ps1')"))
  }

  It "Sync-ShellProfile does not embed a literal copy of the profile body" {
    $syncContent = Get-SyncShellProfileContent
    $syncContent | Should -Not -Match ([regex]::Escape((Get-ProfileContent)))
  }

  It "pwsh.nix reads the shared profile" {
    $pwshNixContent = Get-PwshNixContent
    $pwshNixContent | Should -Match ([regex]::Escape("builtins.readFile ../scripts/shell/init.ps1 + builtins.readFile ../scripts/shell/profile.ps1"))
  }
}

Describe "Windows render token completeness" {
  It "every profile.ps1 token is replaced by Sync-ShellProfile" {
    $profileTokens = Get-UpperSnakeTokenList $ProfilePath
    $syncReplaceTokens = @([regex]::Matches((Get-SyncShellProfileContent), "-replace '__[A-Z][A-Z_]*__'") | ForEach-Object { $_.Value -replace "-replace '", "" -replace "'", "" } | Sort-Object -Unique)
    $missing = @($profileTokens | Where-Object { $_ -notin $syncReplaceTokens })
    $missing | Should -BeNullOrEmpty
  }

  It "every Sync-ShellProfile replacement targets a real profile.ps1 token" {
    $profileTokens = Get-UpperSnakeTokenList $ProfilePath
    $syncReplaceTokens = @([regex]::Matches((Get-SyncShellProfileContent), "-replace '__[A-Z][A-Z_]*__'") | ForEach-Object { $_.Value -replace "-replace '", "" -replace "'", "" } | Sort-Object -Unique)
    $dangling = @($syncReplaceTokens | Where-Object { $_ -notin $profileTokens })
    $dangling | Should -BeNullOrEmpty
  }
}

Describe "POSIX render token completeness" {
  It "every profile.ps1 token is replaced by pwsh.nix replaceStrings" {
    $profileTokens = Get-UpperSnakeTokenList $ProfilePath
    $nixReplaceTokens = @([regex]::Matches((Get-PwshNixContent), '"__[A-Z][A-Z_]*__"') | ForEach-Object { $_.Value.Trim('"') } | Sort-Object -Unique)
    $missing = @($profileTokens | Where-Object { $_ -notin $nixReplaceTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "No legacy token syntax in profile chain" {
  It "profile.ps1 and Sync-ShellProfile contain no {{ placeholders" {
    (Get-ProfileContent) | Should -Not -Match '\{\{[A-Za-z_]'
    (Get-SyncShellProfileContent) | Should -Not -Match '\{\{[A-Za-z_]'
  }
}
