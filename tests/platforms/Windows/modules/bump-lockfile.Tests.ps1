<#
.SYNOPSIS
  Pester tests for scripts/bump-lockfile.ps1 verify and no-change stability.

.DESCRIPTION
  Verifies that --verify compares canonically (parsed + re-serialized JSON,
  not raw file text), that a no-change run does not rewrite the lockfile, and
  that 'updated' is stamped only when a real change is written.

  Also covers the cargo-binstall section: the crates.io API with the cargo
  search fallback, and the 'cargo' section alias. Plus the CLI surface:
  -ListSections output, unknown-section validation, and the no-updater skip
  message.

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
    New-Item -Path $lockfileDir -ItemType Directory -Force > $null
    [System.IO.File]::WriteAllText(
      (Join-Path $lockfileDir 'lockfile.json'),
      $fixtureJson,
      [System.Text.UTF8Encoding]::new($false)
    )

    # Fake curl: prints the version stored in curl-bun-version. Dual shim so
    # tests run on Windows CI (curl.cmd) and POSIX pwsh (curl).
    $binDir = Join-Path $Script:FixtureRoot 'bin'
    New-Item -Path $binDir -ItemType Directory -Force > $null
    Set-Content -Path (Join-Path $binDir 'curl-bun-version') -Value '1.0.0' -NoNewline
    Set-Content -Path (Join-Path $binDir 'curl.cmd') -Value "@echo off`r`nset /p VER=<%~dp0curl-bun-version`r`necho {`"version`":`"%VER%`"}" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'curl') -Value "#!/bin/sh`nprintf '{""version"":""%s""}\n' ""`$(cat ""`$(dirname ""`$0"")/curl-bun-version"")""" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses curl.cmd instead.
      & chmod +x (Join-Path $binDir 'curl')
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

    # Fake rustup: echoes the toolchain-list line stored in rustup-output.
    # Dual shim so tests run on Windows CI (rustup.cmd) and POSIX pwsh (rustup).
    Set-Content -Path (Join-Path $binDir 'rustup-output') -Value 'stable-aarch64-pc-windows-msvc (default)' -NoNewline
    Set-Content -Path (Join-Path $binDir 'rustup.cmd') -Value "@echo off`r`nset /p OUT=<%~dp0rustup-output`r`necho %OUT%" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'rustup') -Value "#!/bin/sh`ncat `"`$(dirname `"`$0`")/rustup-output`"" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses rustup.cmd instead.
      & chmod +x (Join-Path $binDir 'rustup')
    }

    # Fake rustc: echoes the version line stored in rustc-output.
    # Dual shim so tests run on Windows CI (rustc.cmd) and POSIX pwsh (rustc).
    Set-Content -Path (Join-Path $binDir 'rustc-output') -Value 'rustc 1.95.0 (59807616e 2026-04-14)' -NoNewline
    Set-Content -Path (Join-Path $binDir 'rustc.cmd') -Value "@echo off`r`nset /p OUT=<%~dp0rustc-output`r`necho %OUT%" -Encoding ASCII
    Set-Content -Path (Join-Path $binDir 'rustc') -Value "#!/bin/sh`ncat `"`$(dirname `"`$0`")/rustc-output`"" -Encoding ASCII
    if (-not $IsWindows) {
      # POSIX requires the executable bit; Windows CI uses rustc.cmd instead.
      & chmod +x (Join-Path $binDir 'rustc')
    }
  }

  function Set-FakeBunVersion {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes a version file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Version)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/curl-bun-version') -Value $Version -NoNewline
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

  function Set-FakeRustupOutput {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes an output file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Output)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/rustup-output') -Value $Output -NoNewline
  }

  function Set-FakeRustcOutput {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes an output file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Output)
    Set-Content -Path (Join-Path $Script:FixtureRoot 'bin/rustc-output') -Value $Output -NoNewline
  }

  function Invoke-BumpLockfile {
    param(
      [string[]]$Arguments,
      [string]$FixtureVersion = '1.0.0'
    )
    Set-FakeBunVersion -Version $FixtureVersion
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

Describe 'bump-lockfile.ps1 rustup (version pin for stable, not date)' {
  BeforeEach {
    New-FixtureRepo
    # Add a rustup section with a stable key to the fixture lockfile.
    $lockfilePath = Join-Path $Script:FixtureRoot 'src/lockfiles/lockfile.json'
    $ht = Get-Content -Raw $lockfilePath | ConvertFrom-Json -AsHashtable
    $ht['rustup'] = @{ stable = '1.90.0' }
    $ht | ConvertTo-Json -Depth 10 | Set-Content -Path $lockfilePath -Encoding UTF8
  }

  It 'records the version (not a date) for stable' {
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'rustup')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Match '"stable": "1\.95\.0"'
    Get-FixtureContent | Should -Not -Match '2026-04-14'
  }
}

Describe 'bump-lockfile.ps1 -ListSections' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'prints exactly the 19 canonical section names in alphabetical order' {
    $expected = @(
      'bun',
      'cargo',
      'cargo-binstall',
      'pwsh',
      'rustup',
      'scoop',
      'source-builds',
      'uv',
      'version',
      'vm-setup',
      'vm-setup.nixos-iso',
      'vm-setup.tart-images',
      'vm-setup.windows',
      'winget',
      'suggestions.homebrew',
      'suggestions.homebrew.masApps',
      'suggestions.ollama',
      'suggestions.vscode',
      'suggestions.vm-setup.windows'
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

Describe 'bump-lockfile.ps1 missing-tool guards' {
  BeforeEach {
    New-FixtureRepo
  }

  It 'warns and skips winget when the tool is absent, and never aborts' {
    $before = Get-FixtureContent
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'winget')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Be $before
    if (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {  # check-suppress:suppression_doc: probe -- tool may be absent; the guard only asserts the skip message when present
      $result.Output | Should -Match 'winget not found — skipping winget section'
    }
  }

  It 'warns and skips scoop when the tool is absent, and never aborts' {
    $before = Get-FixtureContent
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'scoop')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Be $before
    if (-not (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue)) {  # check-suppress:suppression_doc: probe -- tool may be absent; the guard only asserts the skip message when present
      $result.Output | Should -Match 'scoop not found — skipping scoop section'
    }
  }

  It 'warns and skips the bun section when curl is absent, and never aborts' {
    $before = Get-FixtureContent
    # The fixture ships a fake curl; remove it so the guard path is exercised.
    Remove-Item -LiteralPath (Join-Path $Script:FixtureRoot 'bin/curl') -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- file may not exist on this platform; absence is the expected pass
    Remove-Item -LiteralPath (Join-Path $Script:FixtureRoot 'bin/curl.cmd') -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- file may not exist on this platform; absence is the expected pass
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'bun')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Be $before
    if (-not (Get-Command -Name 'curl' -ErrorAction SilentlyContinue)) {  # check-suppress:suppression_doc: probe -- tool may be absent; the guard only asserts the skip message when present
      $result.Output | Should -Match 'curl: command not found — skipping bun section'
    }
  }

  It 'does not abort on uv/rustup/pwsh/suggestions.ollama when those tools are present' {
    # The fixture has no keys for these sections, so a present tool is a
    # no-op; the regression being guarded is the old abort-on-missing-command
    # behavior. Absent tools warn and skip (covered above); present tools must
    # run without throwing.
    $before = Get-FixtureContent
    $result = Invoke-BumpLockfile -Arguments @('-Sections', 'uv,rustup,pwsh,suggestions.ollama')
    $result.ExitCode | Should -Be 0
    Get-FixtureContent | Should -Be $before
  }
}
