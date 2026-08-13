<#
.SYNOPSIS
  Pester tests for scripts/bump-lockfile.ps1 verify and no-change stability.

.DESCRIPTION
  Verifies that --verify compares canonically (parsed + re-serialized JSON,
  not raw file text), that a no-change run does not rewrite the lockfile, and
  that 'updated' is stamped only when a real change is written.

  Also covers the cargo-binstall section: the crates.io API with the cargo
  search fallback, and the 'cargo' section alias. Plus the CLI surface:
  -ListSections output, unknown-section validation, the homebrew section via
  a fake brew, and the no-updater skip message.

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
    "nucleus-bump-lockfile-fixture-crate-does-not-exist": "0.1.0"
  },
  "homebrew": {
    "brews": {
      "fixture-brew-pkg": "0.9.0"
    }
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

    # Fake cargo: echoes the crates.io-fallback output stored in cargo-output.
    # Dual shim so tests run on Windows CI (cargo.cmd) and POSIX pwsh (cargo).
    Set-Content -Path (Join-Path $binDir 'cargo-output') -Value '' -NoNewline
    Set-Content -Path (Join-Path $binDir 'cargo.cmd') -Value "@echo off`r`nset /p OUT=<%~dp0cargo-output`r`necho %OUT%" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'cargo') -Value "#!/bin/sh`ncat `"`$(dirname `"`$0`")/cargo-output`"" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses cargo.cmd instead.
      & chmod +x (Join-Path $binDir 'cargo')
    }

    # Fake brew: echoes the canned line stored in brew-output for any
    # invocation. Dual shim so tests run on Windows CI (brew.cmd) and POSIX
    # pwsh (brew).
    Set-Content -Path (Join-Path $binDir 'brew-output') -Value 'fixture-brew-pkg 0.9.0' -NoNewline
    Set-Content -Path (Join-Path $binDir 'brew.cmd') -Value "@echo off`r`nset /p OUT=<%~dp0brew-output`r`necho %OUT%" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'brew') -Value "#!/bin/sh`ncat `"`$(dirname `"`$0`")/brew-output`"" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses brew.cmd instead.
      & chmod +x (Join-Path $binDir 'brew')
    }
  }

  function Set-FakeNpmVersion {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes a version file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Version)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/npm-version') -Value $Version -NoNewline
  }

  function Set-FakeCargoOutput {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes an output file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Output)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/cargo-output') -Value $Output -NoNewline
  }

  function Set-FakeBrewOutput {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes an output file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Output)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/brew-output') -Value $Output -NoNewline
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

Describe 'bump-lockfile.ps1 cargo-binstall (crates.io + cargo search fallback)' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'resolves the cargo alias to the cargo-binstall section and falls back to cargo search' {
    Set-FakeCargoOutput -Output 'nucleus-bump-lockfile-fixture-crate-does-not-exist = "2.0.0"'
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'cargo')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Match '"nucleus-bump-lockfile-fixture-crate-does-not-exist": "2\.0\.0"'
  }

  It 'falls back to cargo search when the crates.io API 404s' {
    Set-FakeCargoOutput -Output 'nucleus-bump-lockfile-fixture-crate-does-not-exist = "2.0.0"'
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'cargo-binstall')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Match '"nucleus-bump-lockfile-fixture-crate-does-not-exist": "2\.0\.0"'
  }

  It 'warns and leaves the entry unchanged when both version sources fail' {
    Set-FakeCargoOutput -Output ''
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'cargo-binstall')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'no version source'
    Get-FixtureContent | Should -Match '"nucleus-bump-lockfile-fixture-crate-does-not-exist": "0\.1\.0"'
  }
}

Describe 'bump-lockfile.ps1 -ListSections' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'prints exactly the 24 canonical section names in alphabetical order' {
    $expected = @(
      'bun',
      'camilladsp',
      'camillagui-backend',
      'cargo',
      'cargo-binstall',
      'homebrew',
      'homebrew.brews',
      'homebrew.casks',
      'homebrew.masApps',
      'ollama',
      'pwsh',
      'rustup',
      'sccache',
      'scoop',
      'source-builds',
      'starship',
      'uv',
      'version',
      'vm-setup',
      'vm-setup.nixos-iso',
      'vm-setup.tart-images',
      'vm-setup.windows',
      'vscode',
      'winget'
    )
    $result = Invoke-BumpLockfile -Arguments @('-ListSections')
    $result.ExitCode | Should -Be 0
    $result.Output -split "`n" | Should -Be $expected
  }
}

Describe 'bump-lockfile.ps1 -Sections validation' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'rejects an unknown section with the valid list on stderr and exit 1' {
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'bogus')
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Match "unknown section 'bogus'"
    $result.Output | Should -Match 'valid:'
  }
}

Describe 'bump-lockfile.ps1 homebrew section' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'updates a brew pin from the fake brew list --versions output' {
    Set-FakeBrewOutput -Output 'fixture-brew-pkg 9.9.9'
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'homebrew.brews')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'updating homebrew\.brews\.fixture-brew-pkg'
    Get-FixtureContent | Should -Match '"fixture-brew-pkg": "9\.9\.9"'
  }
}

Describe 'bump-lockfile.ps1 no-updater sections' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'skips an explicitly selected no-updater section without failing' {
    $before = Get-FixtureContent
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'version')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'no updater'
    Get-FixtureContent | Should -Be $before
  }
}
