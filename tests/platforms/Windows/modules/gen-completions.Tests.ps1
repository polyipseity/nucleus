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

  Every hand-coded PowerShell subcommand array (gc, svc, config, logs, utils,
  vm) is also pinned to the subcommand constraint of its Windows app: a
  subcommand an app accepts but a completer never offers ships silently, which is
  how nucleus-gc logs stayed undiscoverable, and how nucleus-gc all stayed
  unofferable.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/gen-completions.Tests.ps1 -Passthru"
#>

BeforeAll {
  function Test-NucleusFlagAppliesToWindows($f) {
    $p = if ($f -is [System.Collections.IDictionary]) { $f['platforms'] } else { $prop = $f.PSObject.Properties['platforms']; if ($null -eq $prop) { $null } else { $prop.Value } }
    if ($null -eq $p) { return $true }
    $vals = @($p)
    return ($vals.Count -eq 0 -or $vals -contains 'windows')
  }

  $Script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-gen-completions-tests'
  $Script:ScriptPath = Join-Path $PSScriptRoot '../../../../src/scripts/completions/gen-completions.ps1'
  $Script:RealProfilePath = Join-Path $PSScriptRoot '../../../../src/scripts/shell/profile.ps1'
  $Script:RepoRoot = Join-Path $PSScriptRoot '../../../..'
  $Script:PwshExe = (Get-Command pwsh).Source

  # The six commands whose PowerShell completer keeps its subcommand list by
  # hand, with the constraint in the Windows app that is the source of truth for
  # it: a ValidateSet on the entry-point parameter, or the command switch in
  # config.ps1, the one app of the six with no ValidateSet.
  $Script:SubcommandSources = [ordered]@{
    'gc'     = @{ App = 'scripts/gc.ps1'; Mechanism = 'ValidateSet'; Anchor = ''; Variable = 'nucleusGcCommands' }
    'svc'    = @{ App = 'scripts/svc.ps1'; Mechanism = 'ValidateSet'; Anchor = ''; Variable = 'nucleusSvcCommands' }
    'config' = @{ App = 'scripts/config.ps1'; Mechanism = 'switch'; Anchor = 'switch ($Command) {'; Variable = 'nucleusConfigCommands' }
    'logs'   = @{ App = 'scripts/logs.ps1'; Mechanism = 'ValidateSet'; Anchor = ''; Variable = 'nucleusLogsCommands' }
    'utils'  = @{ App = 'scripts/utils.ps1'; Mechanism = 'ValidateSet'; Anchor = ''; Variable = 'nucleusUtilsCommands' }
    'vm'     = @{ App = 'scripts/vm.ps1'; Mechanism = 'ValidateSet'; Anchor = ''; Variable = 'nucleusVmCommands' }
  }

  function New-FixtureProfile {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test fixture mutates a temp dir; no ShouldProcess in tests
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    if (Test-Path -LiteralPath $Script:FixtureRoot -PathType Container) {
      Remove-Item -LiteralPath $Script:FixtureRoot -Recurse -Force
    }
    $profileDir = Join-Path $Script:FixtureRoot 'src/scripts/shell'
    $manifestDir = Join-Path $Script:FixtureRoot 'src/modules/completions'
    New-Item -Path $profileDir -ItemType Directory -Force > $null
    New-Item -Path $manifestDir -ItemType Directory -Force > $null
    # Copy-Item preserves bytes, keeping the real file's CRLF + UTF-8 encoding.
    Copy-Item -LiteralPath $Script:RealProfilePath -Destination (Join-Path $profileDir 'profile.ps1')
    Copy-Item -LiteralPath (Join-Path $Script:RepoRoot 'src/modules/completions/nucleus-apps.json') -Destination (Join-Path $manifestDir 'nucleus-apps.json')
    Copy-Item -LiteralPath (Join-Path $Script:RepoRoot 'src/modules/completions/nucleus-cli-spec.json') -Destination (Join-Path $manifestDir 'nucleus-cli-spec.json')
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
    # suite running concurrently in this process: steps share one PowerShell
    # process, so a child spawned by another suite would resolve the wrong repo
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

  function Get-ProfileSubcommandList {
    param(
      [Parameter(Mandatory)]
      [string]$VariableName,
      [Parameter(Mandatory)]
      [string]$ProfileText
    )
    $match = [regex]::Match($ProfileText, [regex]::Escape("`$$VariableName = @(") + "(?<list>[^)]*)\)")
    if (-not $match.Success) {
      return @()
    }
    return @([regex]::Matches($match.Groups['list'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  }

  function Compare-SubcommandList {
    # The labels that are one-sided between an expected list and an actual
    # list, expected-only first and then actual-only. -Direction narrows the
    # result to one side so a caller can still say which way a difference runs.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
      [Parameter(Mandatory)]
      [AllowEmptyCollection()]
      [string[]]$Expected,
      [Parameter(Mandatory)]
      [AllowEmptyCollection()]
      [string[]]$Actual,
      [ValidateSet('Both', 'Missing', 'Surplus')]
      [string]$Direction = 'Both'
    )
    $missing = @($Expected | Where-Object { $Actual -notcontains $_ })
    $surplus = @($Actual | Where-Object { $Expected -notcontains $_ })
    switch ($Direction) {
      'Missing' { return $missing }
      'Surplus' { return $surplus }
      'Both' { return @($missing + $surplus) }
      default { throw "Unknown direction '$Direction'." }
    }
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

  It 'offers every subcommand each Windows app accepts' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile

    # WHY: spec is the authoritative subcommand source. Parsing app source
    # (ValidateSet/switch) regresses when the app moves to $ValidActions.
    $spec = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'src/modules/completions/nucleus-cli-spec.json') -Raw | ConvertFrom-Json -AsHashtable
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($command in $Script:SubcommandSources.Keys) {
      $source = $Script:SubcommandSources[$command]
      $app = @($spec.apps | Where-Object { $_.name -eq $command }) | Select-Object -First 1
      $accepted = @()
      if ($app -and $app.subcommands) {
        $accepted = @($app.subcommands | ForEach-Object { $_.name } | Where-Object { $_ })
      }
      if ($accepted.Count -eq 0) {
        $failures.Add("${command}: spec yielded no subcommand labels")
        continue
      }
      $offered = @(Get-ProfileSubcommandList -VariableName $source.Variable -ProfileText $profileText)
      if ($offered.Count -eq 0) {
        $failures.Add("${command}: `$$($source.Variable) is missing or empty in profile.ps1")
        continue
      }
      $missing = @(Compare-SubcommandList -Expected $accepted -Actual $offered -Direction 'Missing')
      $stale = @(Compare-SubcommandList -Expected $accepted -Actual $offered -Direction 'Surplus')
      if ($missing.Count -gt 0) {
        $failures.Add("${command}: not offered: " + ($missing -join ', '))
      }
      if ($stale.Count -gt 0) {
        $failures.Add("${command}: offered but never accepted: " + ($stale -join ', '))
      }
    }
    ($failures -join '; ') | Should -BeNullOrEmpty -Because (
      'nucleus-<command> must complete every subcommand the spec declares, and nothing stale')
  }

  It 'gc flags include the full generated set' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    # --system-gc/--nix-artifacts-gc/--journald-gc are POSIX-only in spec; Windows generator filters them out.
    foreach ($flag in '--tool-cache-gc', '--vm-data-gc', '--git-cache-gc', '--log-gc', '--scoop-gc') {
      $profileText | Should -Match ([regex]::Escape($flag))
    }
  }

  It 'config flags derive from spec (no corrupt scalar)' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    # Regression: if-expression unrolling once wrote "-" instead of "--help".
    $spec = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'src/modules/completions/nucleus-cli-spec.json') -Raw | ConvertFrom-Json -AsHashtable
    $configApp = @($spec.apps | Where-Object { $_.name -eq 'config' }) | Select-Object -First 1
    $expected = @()
    if ($configApp) {
      foreach ($f in @($configApp.globalFlags)) {
        if ($f.long -and (Test-NucleusFlagAppliesToWindows $f)) { $expected += $f.long }
      }
      foreach ($sc in @($configApp.subcommands)) {
        foreach ($f in @($sc.flags)) {
          if ($f.long -and (Test-NucleusFlagAppliesToWindows $f)) { $expected += $f.long }
        }
      }
    }
    $expected = @($expected | Sort-Object -Unique)
    $actual = @(Get-NucleusFlagsFromProfile -VariableName 'nucleusConfigFlags' -ProfileText $profileText | Sort-Object -Unique)
    $actual | Should -Be $expected
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

  It 'Windows nucleus-ai completer mirrors ai.ps1 params and profile aliases' {
    $null = Invoke-GenCompletion  # check-suppress:suppression_doc: Invoke-GenCompletion returns the generated profile text; output discarded because the test reads the fixture file instead
    $profileText = Get-FixtureProfile
    $aiBlock = [regex]::Match(
      $profileText,
      'Register-ArgumentCompleter -CommandName nucleus-ai -ScriptBlock \{.*?\n\}',
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Value
    $aiBlock | Should -Not -Be ''
    # Windows flags must bind to scripts/ai.ps1 params (DryRun, GcOnly,
    # AiProfile, Json, Help) and accepted profile aliases.
    $aiBlock | Should -Match ([regex]::Escape("'--ai-profile'"))
    $aiBlock | Should -Match ([regex]::Escape("'--dry-run'"))
    $aiBlock | Should -Match ([regex]::Escape("'--gc-only'"))
    $aiBlock | Should -Match ([regex]::Escape("'--json'"))
    $aiBlock | Should -Match ([regex]::Escape("'--ollama-profile'"))
    $aiBlock | Should -Match ([regex]::Escape("'--profile'"))
    $aiBlock | Should -Not -Match ([regex]::Escape("'--no-gc-only'"))
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

    # WHY: derive from spec so flag additions do not require a second manual table.
    $spec = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'src/modules/completions/nucleus-cli-spec.json') -Raw | ConvertFrom-Json -AsHashtable
    $appVars = [ordered]@{
      'ai'    = 'nucleusAiFlags'
      'utils' = 'nucleusUtilsFlags'
      'svc'   = 'nucleusSvcFlags'
      'test'  = 'nucleusTestFlags'
      'vm'    = 'nucleusVmFlags'
    }
    foreach ($appName in $appVars.Keys) {
      $varName = $appVars[$appName]
      $app = @($spec.apps | Where-Object { $_.name -eq $appName }) | Select-Object -First 1
      $expected = @()
      if ($app) {
        foreach ($f in @($app.globalFlags)) {
          if ($f.long -and (Test-NucleusFlagAppliesToWindows $f)) { $expected += $f.long }
        }
        foreach ($sc in @($app.subcommands)) {
          foreach ($f in @($sc.flags)) {
            if ($f.long -and (Test-NucleusFlagAppliesToWindows $f)) { $expected += $f.long }
          }
        }
      }
      $expected = @($expected | Sort-Object -Unique)
      $actual = @(Get-NucleusFlagsFromProfile -VariableName $varName -ProfileText $profileText | Sort-Object -Unique)
      $actual | Should -Be $expected -Because "$appName flags must match spec"
    }

    $vmFlags = @(Get-NucleusFlagsFromProfile -VariableName 'nucleusVmFlags' -ProfileText $profileText)
    $vmFlags | Should -Not -Contain '--no-windows-iso'
    $profileText | Should -Not -Match '--remove-backup'
  }
}

Describe 'Compare-SubcommandList' {
  It 'reports nothing for identical lists' {
    $difference = Compare-SubcommandList -Expected @('a', 'b') -Actual @('b', 'a')
    ($difference -join ',') | Should -BeExactly ''
  }

  It 'names a label missing from the expected list' {
    $difference = Compare-SubcommandList -Expected @('a', 'b') -Actual @('a', 'b', 'c')
    ($difference -join ',') | Should -BeExactly 'c'
  }

  It 'names a label surplus to the expected list' {
    $difference = Compare-SubcommandList -Expected @('a', 'b') -Actual @('a', 'b', 'c') -Direction 'Surplus'
    ($difference -join ',') | Should -BeExactly 'c'
  }

  It 'names a label missing from the actual list' {
    $difference = Compare-SubcommandList -Expected @('a', 'b', 'c') -Actual @('a', 'b') -Direction 'Missing'
    ($difference -join ',') | Should -BeExactly 'c'
  }

  It 'reports nothing for two empty lists' {
    $difference = Compare-SubcommandList -Expected @() -Actual @()
    ($difference -join ',') | Should -BeExactly ''
  }
}
