<#
.SYNOPSIS
  Pester tests for src/scripts/completions/gen-completions.ps1.

.DESCRIPTION
  Verifies the generated completer flag inventory contract: -Help exits 0,
  -Check reports up to date on an identical profile.ps1 and detects drift,
  a write run is idempotent (byte-stable), every nucleus-* command gets a
  generated $nucleus<Cmd>Flags array, the hand-coded glue arrays and completer
  blocks survive regeneration, and single-flag commands get a full '--help'
  entry (regression: if-expression unrolling once emitted a corrupt '-' line).

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/gen-completions.Tests.ps1 -Passthru"
#>

BeforeAll {
  $Script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-gen-completions-tests'
  $Script:ScriptPath = Join-Path $PSScriptRoot '../../../../src/scripts/completions/gen-completions.ps1'
  $Script:RealProfilePath = Join-Path $PSScriptRoot '../../../../src/scripts/shell/profile.ps1'
  $Script:PwshExe = (Get-Command pwsh).Source

  function New-FixtureProfile {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture mutates a temp dir; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    if (Test-Path -LiteralPath $Script:FixtureRoot -PathType Container) {
      Remove-Item -LiteralPath $Script:FixtureRoot -Recurse -Force
    }
    $profileDir = Join-Path $Script:FixtureRoot 'src/scripts/shell'
    New-Item -Path $profileDir -ItemType Directory -Force > $null
    # Copy-Item preserves bytes, keeping the real file's CRLF + UTF-8 encoding.
    Copy-Item -LiteralPath $Script:RealProfilePath -Destination (Join-Path $profileDir 'profile.ps1')
  }

  function Get-FixtureProfile {
    return [System.IO.File]::ReadAllText((Join-Path $Script:FixtureRoot 'src/scripts/shell/profile.ps1'))
  }

  function Set-FixtureProfile {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture writes a temp file; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Content)
    [System.IO.File]::WriteAllText(
      (Join-Path $Script:FixtureRoot 'src/scripts/shell/profile.ps1'),
      $Content,
      [System.Text.UTF8Encoding]::new($false)
    )
  }

  function Invoke-GenCompletion {
    param([string[]]$Arguments)
    # WHY: the fixture repo root is handed to the child through the child's own
    # environment. Setting $env:NUCLEUS_REPO_ROOT here would leak into every
    # suite running concurrently in this process — steps share one PowerShell
    # process — so a child spawned by another suite would resolve the wrong repo
    # root (scripts/check.ps1 reads NUCLEUS_REPO_ROOT when it is set).
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Script:PwshExe
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['NUCLEUS_REPO_ROOT'] = $Script:FixtureRoot
    $childArguments = @('-NoProfile', '-File', $Script:ScriptPath)
    if ($Arguments) { $childArguments += $Arguments }
    foreach ($argument in $childArguments) {
      $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # WHY: both streams are read asynchronously; reading one to the end while the
    # child fills the other stream's buffer can deadlock.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ Output = ($stdout.Result + $stderr.Result); ExitCode = $process.ExitCode }
  }

  function Get-NucleusFlagsFromProfile {
    param(
      [Parameter(Mandatory)]
      [string]$VariableName,
      [Parameter(Mandatory)]
      [string]$ProfileText
    )
    $pattern = [regex]::Escape("`$$VariableName = @(") + "`r?`n(?<flags>(?:  '[^']+'(?:,)?`r?`n)*)\)"
    $match = [regex]::Match($ProfileText, $pattern)
    if (-not $match.Success) {
      return @()
    }
    return @([regex]::Matches($match.Groups['flags'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  }
}

AfterAll {
  if (Test-Path -LiteralPath $Script:FixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $Script:FixtureRoot -Recurse -Force
  }
}

Describe 'gen-completions.ps1 CLI surface' {
  BeforeEach {
    New-FixtureProfile
  }

  It '-Help exits 0 and shows help' {
    $result = Invoke-GenCompletion -Arguments @('-Help')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'SYNOPSIS'
  }

  It '-Check exits 0 on an identical profile.ps1' {
    $result = Invoke-GenCompletion -Arguments @('-Check')
    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'up to date'
  }

  It '-Check exits 1 on drift and lists the diff' {
    $content = Get-FixtureProfile
    Set-FixtureProfile -Content ($content.Replace("'--json'", "'--json2'"))
    $result = Invoke-GenCompletion -Arguments @('-Check')
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Match 'out of date'
    $result.Output | Should -Match '--json2'
  }

  It 'a write run is idempotent (byte-stable)' {
    $first = Invoke-GenCompletion
    $first.ExitCode | Should -Be 0
    $contentAfterFirst = Get-FixtureProfile
    $second = Invoke-GenCompletion
    $second.ExitCode | Should -Be 0
    Get-FixtureProfile | Should -Be $contentAfterFirst
  }
}

Describe 'gen-completions.ps1 generated inventory' {
  BeforeEach {
    New-FixtureProfile
  }

  It 'emits a $nucleus<Cmd>Flags array for every nucleus-* command' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $listResult = Invoke-GenCompletion -Arguments @('-ListCommands')
    # WHY: the child writes the command list with the platform newline, so a CRLF
    # host leaves a trailing CR on every line; splitting on LF alone would keep
    # it inside the derived PascalCase name and the pattern would never match.
    $commands = $listResult.Output -split "`r?`n" | Where-Object { $_.Trim() }
    $profileText = Get-FixtureProfile
    foreach ($command in $commands) {
      $pascal = (($command.Split('-') | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '')
      $profileText | Should -Match ([regex]::Escape("`$nucleus${pascal}Flags = @("))
    }
  }

  It 'keeps the hand-coded glue: gc completer and $nucleusSvcCommands' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    $profileText | Should -Match 'Register-ArgumentCompleter -CommandName nucleus-gc '
    $profileText | Should -Match "'verify'"
  }

  It 'gc flags include the full generated set' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    foreach ($flag in '--tool-cache-gc', '--system-gc', '--nix-artifacts-gc', '--vm-data-gc', '--journald-gc') {
      $profileText | Should -Match ([regex]::Escape($flag))
    }
  }

  It 'single-flag commands get a full --help entry (no corrupt scalar)' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    # Regression: if-expression unrolling once wrote "-" instead of "--help".
    $profileText | Should -Match ([regex]::Escape("`$nucleusConfigFlags = @(") + "`r?`n  '--help'`r?`n\)")
    $profileText | Should -Not -Match ([regex]::Escape("`$nucleusConfigFlags = @(") + "`r?`n  '-'`r?`n\)")
  }

  It 'vm setup flags derive from the generated inventory (no stale --no-windows-iso)' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    # The setup-specific subset must be derived from the generated inventory so
    # it can never drift; android-config-only flags are the exclusion list.
    $profileText | Should -Match ([regex]::Escape('$nucleusVmSetupFlags = $nucleusVmFlags | Where-Object'))
    $profileText | Should -Match ([regex]::Escape("'--fake-wifi-revert'"))
    # Stale flags that never existed in vm.sh must be absent everywhere.
    $profileText | Should -Not -Match '--no-windows-iso'
    $profileText | Should -Not -Match '--no-windows-iso-source'
  }

  It 'Windows nucleus-ai completer mirrors ai.ps1 params (no POSIX-only spellings)' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    $aiBlock = [regex]::Match(
      $profileText,
      'Register-ArgumentCompleter -CommandName nucleus-ai -ScriptBlock \{.*?\n\}',
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Value
    $aiBlock | Should -Not -Be ''
    # Windows flags must bind to scripts/ai.ps1 params (DryRun, GcOnly,
    # AiProfile, Json, Help); POSIX-only ai.sh spellings are rejected.
    $aiBlock | Should -Match ([regex]::Escape("'--ai-profile'"))
    $aiBlock | Should -Match ([regex]::Escape("'--dry-run'"))
    $aiBlock | Should -Match ([regex]::Escape("'--gc-only'"))
    $aiBlock | Should -Match ([regex]::Escape("'--json'"))
    $aiBlock | Should -Not -Match ([regex]::Escape("'--ollama-profile'"))
    $aiBlock | Should -Not -Match ([regex]::Escape("'--no-gc-only'"))
    $aiBlock | Should -Not -Match ([regex]::Escape("'--profile'"))
  }

  It 'keeps the generated region markers' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    $profileText | Should -Match '# --- BEGIN GENERATED completer flag inventory ---'
    $profileText | Should -Match '# --- END GENERATED ---'
    $profileText | Should -Match '# GENERATED by src/scripts/completions/gen-completions.ps1 - do not hand-edit\.'
  }

  It 'fixed flag sets match the authoritative table' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile

    # Commands whose generated (sorted) order equals the authoritative table.
    @(Get-NucleusFlagsFromProfile -VariableName 'nucleusAiFlags' -ProfileText $profileText) | Should -Be @('--dry-run', '--gc-only', '--help', '--json', '--no-gc-only', '--ollama-profile', '--profile')
    @(Get-NucleusFlagsFromProfile -VariableName 'nucleusUtilsFlags' -ProfileText $profileText) | Should -Be @('--dialog', '--help', '--preset', '--rm-bak')
    @(Get-NucleusFlagsFromProfile -VariableName 'nucleusSvcFlags' -ProfileText $profileText) | Should -Be @('--help', '--json', '--system', '--user', '--verbose')

    # test/vm: the generator re-sorts via Sort-Object (e.g. '-q' sorts last), so
    # assert the SET order-independently plus absence of the stale flags.
    $testFlags = @(Get-NucleusFlagsFromProfile -VariableName 'nucleusTestFlags' -ProfileText $profileText)
    $testExpected = @('-q', '--fail-fast', '--help', '--no-fail-fast', '--only-steps', '--quiet') | Sort-Object
    @($testFlags | Sort-Object) | Should -Be $testExpected

    $vmFlags = @(Get-NucleusFlagsFromProfile -VariableName 'nucleusVmFlags' -ProfileText $profileText)
    $vmExpected = @('--accept-gsi-license', '--accelerator', '--adb-keys', '--allow-shrink', '--dry-run', '--fake-wifi', '--fake-wifi-revert', '--force', '--gc', '--gc-data', '--gc-disabled', '--gapps', '--headful', '--help', '--json', '--magisk', '--mido-patch-file', '--mido-script', '--no-accept-gsi-license', '--no-gc', '--no-gc-data', '--no-gc-disabled', '--no-headful', '--repo-root', '--root', '--vm-dir-override', '--windows-iso', '--windows-iso-retries', '--windows-iso-source') | Sort-Object
    @($vmFlags | Sort-Object) | Should -Be $vmExpected
    $vmFlags | Should -Not -Contain '--no-windows-iso'
    $profileText | Should -Not -Match '--remove-backup'
  }
}
