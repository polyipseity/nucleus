<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Phase 1 — Syntax: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  Phase 2 — Lint: if PSScriptAnalyzer is available in the current session,
  runs `Invoke-ScriptAnalyzer` sequentially in-process at Error and Warning
  severity with excluded rules that trigger false positives.  If the module is
  absent, a warning is printed and the lint phase is skipped so CI can run on
  machines that do not have PSScriptAnalyzer installed (syntax validation
  still passes).

  By default the script checks every tracked `*.ps1` file in the current Git
  repository.

  This script is intended to be called via the flake app
  `nix run ./src#check-pwsh`, which pins runtime dependencies (`pwsh`, `git`)
  to repository-managed versions.

.PARAMETER SyntaxOnly
  If specified, skip Phase 2 (PSScriptAnalyzer). Used by check.sh for fast
  pre-commit validation; full lint runs in test.sh.

.PARAMETER Scoped
  If specified and no paths are given, skip Git discovery (no files to check).
  Used by check.sh/check.ps1 in scoped mode to skip whole-repo discovery.

.PARAMETER Paths
  Optional file paths to check. When omitted, all tracked `*.ps1` files from
  `git ls-files` are checked (default: none; all tracked .ps1 files).

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- -SyntaxOnly

.EXAMPLE
  nix run ./src#check-pwsh -- src/hosts/Windows/apply.ps1

.NOTES
  Environment variables: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.

  CommandInfo cache pre-population (Phase 1b):
  PSScriptAnalyzer's CommandInfoCache runs Get-Command in a
  RunspacePool(1,10), causing ~4000+ individual cold calls (~60s) across 126
  PS1 files. Phase 1b AST-scans all target files, runs Get-Command once from
  the main runspace, and injects results into PSSA's internal cache via .NET
  reflection.

  Upstream tracking:
  - PSSA #1189 (Get-Command bottleneck):
    https://github.com/PowerShell/PSScriptAnalyzer/issues/1189
  - PSSA PR #1162 (ConcurrentDictionary, pre-population blocked by #8910):
    https://github.com/PowerShell/PSScriptAnalyzer/pull/1162
  - PowerShell #8910 (ScriptBlock not populated without -Name):
    https://github.com/PowerShell/PowerShell/issues/8910
    Our alias/ShouldProcess use case does NOT need ScriptBlock, so #8910
    is not a blocker.
  - Remove this workaround when PSSA ships a native pre-population API or
    when #8910 is fixed and PSSA adopts pre-population.

  Cross-platform parity note:
  This optimization is PowerShell-only (PSScriptAnalyzer runs in-process).
  No cross-platform equivalent exists; the lint phase is pwsh-only.
#>
[CmdletBinding()]
param(
  [switch]$SyntaxOnly,
  [switch]$Scoped,
  [switch]$SkipCachePrepopulation,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Paths -or $Paths.Count -eq 0) {
  if ($Scoped) {
    Write-Output 'No PowerShell files to check (scoped mode).'
    exit 0
  }
  $Paths = @(git ls-files '*.ps1')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-Output 'No PowerShell files to check.'
  exit 0
}

# ---------------------------------------------------------------------------
# Phase 1: Syntax validation via the built-in parser.
# ---------------------------------------------------------------------------
$parseErrors = @($Paths | Sort-Object -Unique | ForEach-Object -Parallel {
  $path = $_
  if (-not (Test-Path -Path $path)) {
    return
  }

  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

  if ($errors) {
    $errors
  }
} -ThrottleLimit ([System.Environment]::ProcessorCount) | Where-Object { $_ -ne $null })

if ($parseErrors.Count -gt 0) {
  foreach ($parseError in $parseErrors) {
    Write-Output ('{0}:{1}:{2}: {3}' -f $parseError.Extent.File, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
  }

  throw 'PowerShell syntax check failed.'
}

Write-Output ("PowerShell syntax check passed for {0} files." -f $Paths.Count)

# ---------------------------------------------------------------------------
# Phase 2: PSScriptAnalyzer lint (best-effort).
# ---------------------------------------------------------------------------
if ($SyntaxOnly) {
  Write-Output 'PowerShell lint skipped (-SyntaxOnly).'
} elseif (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Write-Warning 'PSScriptAnalyzer not found; skipping lint phase. Install it with: Install-Module PSScriptAnalyzer'
}
else {
  # Scope PSModulePath to reduce module-discovery overhead during PSSA rule evaluation.
  $originalPSModulePath = $env:PSModulePath
  try {
    $env:PSModulePath = @(
      "$PSHome/Modules"
      [System.IO.Path]::Combine($HOME, '.local/share/powershell/Modules')
    ) -join [System.IO.Path]::PathSeparator

    Import-Module PSScriptAnalyzer
    # Pre-import commonly-used modules to reduce PSSA's implicit Get-Command overhead during rule evaluation.
    Import-Module PSReadLine -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: PSReadLine may be absent in CI/non-interactive shells; this import is a performance optimization, not required

    # Method 3 (consumed by script at CI time via -SettingsPath): sibling settings file defines Severity and ExcludeRules.
    $settingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

    # -----------------------------------------------------------------------
    # Phase 1b: Pre-populate CommandInfo cache (performance).
    # -----------------------------------------------------------------------
    if (-not $SkipCachePrepopulation) {
      try {
        # Warmup: trigger Helper.Initialize() safely before reflection cache injection.
        # Direct .Value access on _commandInfoCacheLazy before Initialize() causes
        # a NullReferenceException during subsequent Invoke-ScriptAnalyzer calls.
        $null = Invoke-ScriptAnalyzer -ScriptDefinition '1+1' -Settings $settingsFile

        # AST-extract all invoked command names from target .ps1 files.
        $commandNames = @($Paths | Sort-Object -Unique | ForEach-Object -Parallel {
          $path = $_
          if (-not (Test-Path -Path $path)) { return }
          $tokens = $null; $errors = $null
          $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
          if ($errors) { return }
          $commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
          $commands | ForEach-Object {
            $name = $_.GetCommandName()
            if ($name) { $name }
          }
        } -ThrottleLimit ([System.Environment]::ProcessorCount) | Where-Object { $_ }) | Sort-Object -Unique

        if ($commandNames.Count -gt 0) {
          # Fetch CommandInfo objects from the warm main runspace (single round-trip).
          # check-suppress:suppression_doc: AST-extracted names may include aliases not resolvable as cmdlets; silently skip unresolvable names
          $commandInfos = Get-Command -Name $commandNames -ErrorAction SilentlyContinue

          # Inject found commands into PSSA's internal cache via .NET reflection.
          # PSSA uses a RunspacePool(1,10) for Get-Command lookups; cold cache is ~60s.
          # The ConcurrentDictionary was introduced in PSSA PR #1162; pre-population is
          # blocked upstream by PowerShell #8910 (ScriptBlock not populated without -Name).
          if ($commandInfos) {
            $pssaAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
              Where-Object { $_.GetName().Name -eq 'Microsoft.Windows.PowerShell.ScriptAnalyzer' }

            $helperType = $pssaAssembly.GetType('Microsoft.Windows.PowerShell.ScriptAnalyzer.Helper')
            $helperInstance = $helperType.GetProperty('Instance', [System.Reflection.BindingFlags]'Static,Public').GetValue($null)

            $cacheLazyField = $helperType.GetField('_commandInfoCacheLazy', [System.Reflection.BindingFlags]'NonPublic,Instance')
            $cacheLazy = $cacheLazyField.GetValue($helperInstance)
            $cacheInstance = $cacheLazy.GetType().GetProperty('Value').GetValue($cacheLazy)

            $cacheType = $pssaAssembly.GetType('Microsoft.Windows.PowerShell.ScriptAnalyzer.CommandInfoCache')
            $dictField = $cacheType.GetField('_commandInfoCache', [System.Reflection.BindingFlags]'NonPublic,Instance')
            $dict = $dictField.GetValue($cacheInstance)

            $lookupKeyType = $cacheType.GetNestedType('CommandLookupKey', [System.Reflection.BindingFlags]'NonPublic')
            $lookupKeyCtor = $lookupKeyType.GetConstructors([System.Reflection.BindingFlags]'NonPublic,Instance')[0]
            $tryAddMethod = $dict.GetType().GetMethod('TryAdd')

            foreach ($ci in $commandInfos) {
              $key = $lookupKeyCtor.Invoke(@($ci.Name, $ci.CommandType))
              # Lazy<T>(T) defaults to ExecutionAndPublication thread-safety mode.
              $lazy = [System.Lazy[System.Management.Automation.CommandInfo]]::new($ci)
              $null = $tryAddMethod.Invoke($dict, @([object]$key, $lazy))
            }
          }
        }
      } catch {
        Write-Warning "CommandInfo cache pre-population failed ($($_.Exception.Message)); falling back to uncached PSSA."
      }
    }

    $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })
    $lintResults = $files | Invoke-ScriptAnalyzer -Settings $settingsFile

    if ($lintResults.Count -gt 0) {
      $lintResults | ForEach-Object {
        Write-Output ('{0}:{1}:{2}: [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.Severity, $_.Message)
      }
      throw 'PowerShell lint check failed.'
    }

    Write-Output ("PowerShell lint check passed for {0} files." -f $Paths.Count)
  }
  finally {
    $env:PSModulePath = $originalPSModulePath
  }
}
