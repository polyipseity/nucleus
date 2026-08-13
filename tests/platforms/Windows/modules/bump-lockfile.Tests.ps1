<#
.SYNOPSIS
  Pester tests for scripts/bump-lockfile.ps1 verify and no-change stability.

.DESCRIPTION
  Verifies that --verify compares canonically (parsed + re-serialized JSON,
  not raw file text), that a no-change run does not rewrite the lockfile, and
  that 'updated' is stamped only when a real change is written.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/bump-lockfile.Tests.ps1 -Passthru"
#>

BeforeAll {
  $Script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-bump-lockfile-tests'
  $Script:ScriptPath = Join-Path $PSScriptRoot '../../../../scripts/bump-lockfile.ps1'
  $Script:PwshExe = (Get-Command pwsh).Source

  $fixtureJson = @'
{
  "$schema": "./lockfile.schema.json",
  "bun": {
    "fixture-pkg": "1.0.0"
  },
  "cargo-binstall": {
    "fixture-crate": "0.1.0"
  },
  "updated": "2026-01-01T00:00:00Z",
  "version": 2
}
'@

  function New-FixtureRepo {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture mutates a temp dir; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    if (Test-Path -LiteralPath $Script:FixtureRoot -PathType Container) {
      Remove-Item -LiteralPath $Script:FixtureRoot -Recurse -Force
    }
    $lockfileDir = Join-Path $Script:FixtureRoot 'src/lockfiles'
    New-Item -Path $lockfileDir -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $lockfileDir 'lockfile.json'),
      $fixtureJson,
      [System.Text.UTF8Encoding]::new($false)
    )

    # Fake npm: prints the version stored in npm-version. Dual shim so tests
    # run on Windows CI (npm.cmd) and POSIX pwsh (npm).
    $binDir = Join-Path $Script:FixtureRoot 'bin'
    New-Item -Path $binDir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $binDir 'npm-version') -Value '1.0.0' -NoNewline
    Set-Content -Path (Join-Path $binDir 'npm.cmd') -Value "@echo off`r`nset /p VER=<%~dp0npm-version`r`necho %VER%" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'npm') -Value "#!/bin/sh`ncat `"`$(dirname `"`$0`")/npm-version`"" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses npm.cmd instead.
      & chmod +x (Join-Path $binDir 'npm')
    }
  }

  function Set-FakeNpmVersion {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes a version file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Version)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/npm-version') -Value $Version -NoNewline
  }

  function Invoke-BumpLockfile {
    param(
      [string[]]$Arguments,
      [string]$FixtureVersion = '1.0.0'
    )
    Set-FakeNpmVersion -Version $FixtureVersion
    $oldRepoRoot = $env:NUCLEUS_REPO_ROOT
    $oldPath = $env:PATH
    try {
      $env:NUCLEUS_REPO_ROOT = $Script:FixtureRoot
      $env:PATH = (Join-Path $Script:FixtureRoot 'bin') + [System.IO.Path]::PathSeparator + $oldPath
      $output = & $Script:PwshExe -NoProfile -File $Script:ScriptPath @Arguments 2>&1
      $code = $LASTEXITCODE
    } finally {
      $env:NUCLEUS_REPO_ROOT = $oldRepoRoot
      $env:PATH = $oldPath
    }
    return [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $code }
  }

  function Get-FixtureContent {
    return [System.IO.File]::ReadAllText((Join-Path $Script:FixtureRoot 'src/lockfiles/lockfile.json'))
  }
}

AfterAll {
  if (Test-Path -LiteralPath $Script:FixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $Script:FixtureRoot -Recurse -Force
  }
}

Describe 'bump-lockfile.ps1 --verify' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'passes on an unchanged fixture' {
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'cargo-binstall', '-Verify')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'up to date'
  }

  It 'fails when a section would change, showing the version diff only' {
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'bun', '-Verify') -FixtureVersion '2.0.0'
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Match 'out of date'
    $result.Output | Should -Match 'fixture-pkg'
    $result.Output | Should -Match '2\.0\.0'
    # The canonical comparison must not surface an updated-timestamp diff.
    $result.Output | Should -Not -Match '"updated"'
  }
}

Describe 'bump-lockfile.ps1 write path' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'does not rewrite the file when nothing changed' {
    $before = Get-FixtureContent
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'bun') -FixtureVersion '1.0.0'
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'no changes'
    Get-FixtureContent | Should -Be $before
  }

  It 'writes the file and stamps a fresh updated when a change is made' {
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'bun') -FixtureVersion '2.0.0'
    $result.ExitCode | Should -Be 0
    $content = Get-FixtureContent
    $content | Should -Match '"fixture-pkg": "2\.0\.0"'
    $content | Should -Not -Match '"updated": "2026-01-01T00:00:00Z"'
    $content | Should -Match '"updated": "2026-'
  }
}
