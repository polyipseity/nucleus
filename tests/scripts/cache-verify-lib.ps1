<#
.SYNOPSIS
  Inspects PSScriptAnalyzer's internal CommandInfoCache content for test verification.

.DESCRIPTION
  Provides three functions that reflectively access PSScriptAnalyzer's internal
  CommandInfoCache (ConcurrentDictionary<CommandLookupKey, Lazy<CommandInfo>>)
  and return typed diagnostics about cache contents.

  These functions are pure inspection — they do not modify the cache.

  Dependencies: PSScriptAnalyzer module must be imported and Helper.Instance
  must be initialized before calling these functions.

  When PSScriptAnalyzer is not loaded, Get-CacheContents returns an empty array
  (no error thrown) so tests can safely call it in try/catch or skip checks.

  USAGE NOTE: Collect Get-CacheContents output with @() to guarantee array:
    $contents = @(Get-CacheContents)
    $stats = Get-CacheStats

.EXAMPLE
  Import-Module PSScriptAnalyzer
  . ./tests/scripts/cache-verify-lib.ps1
  $contents = @(Get-CacheContents)
  $stats = Get-CacheStats
  Assert-CacheEntry -Name "Write-Output" -CommandTypes 74 -ExpectedKind Real
#>

function Get-CacheContents {
  <#
  .SYNOPSIS
    Returns all entries from the PSScriptAnalyzer CommandInfoCache.

  .DESCRIPTION
    Reflectively accesses Helper.Instance._commandInfoCacheLazy.Value._commandInfoCache
    and enumerates all entries. Writes each entry as a PSCustomObject to the pipeline
    with fields: Name, CommandTypes (numeric), IsDummy, IsReal, TypeName.

    Uses pipeline-output pattern rather than collecting into a list, because
    PowerShell unrolls collections on function return (an empty collection becomes
    $null on the caller side). Callers should use @(Get-CacheContents) to guarantee
    an array result even when the cache is empty.

    Returns nothing (empty pipeline) if the cache is inaccessible.
  #>
  [CmdletBinding()]
  param()

  try {
    $helperType = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Helper]
    $helper = $helperType::Instance
    if (-not $helper) { return }

    $cacheLazy = $helperType.GetField('_commandInfoCacheLazy', [System.Reflection.BindingFlags]'NonPublic,Instance').GetValue($helper)
    if (-not $cacheLazy) { return }

    $lazyType = $cacheLazy.GetType()
    $cmdInfoCache = $lazyType.GetProperty('Value').GetValue($cacheLazy)
    if (-not $cmdInfoCache) { return }

    $dictField = $cmdInfoCache.GetType().GetField('_commandInfoCache', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $dict = $dictField.GetValue($cmdInfoCache)
    if (-not $dict) { return }

    $cacheType = $cmdInfoCache.GetType()
    $keyType = ($cacheType.GetNestedTypes('NonPublic') | Where-Object { $_.Name -eq 'CommandLookupKey' })[0]
    if (-not $keyType) { return }

    $ctField = $keyType.GetField('CommandTypes', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $nameField = $keyType.GetField('Name', [System.Reflection.BindingFlags]'NonPublic,Instance')
    if (-not $ctField -or -not $nameField) { return }

    $enumerator = $dict.GetEnumerator()
    while ($enumerator.MoveNext()) {
      $kvp = $enumerator.Current
      $name = $nameField.GetValue($kvp.Key)
      $ctRaw = $ctField.GetValue($kvp.Key)
      $lazyValue = $kvp.Value

      $commandInfo = $lazyValue.Value
      $typeName = $commandInfo.GetType().Name
      $isDummy = $commandInfo -is [System.Management.Automation.RemoteCommandInfo]
      $isReal = ($commandInfo -is [System.Management.Automation.CmdletInfo]) -or
                ($commandInfo -is [System.Management.Automation.FunctionInfo])

      [PSCustomObject]@{
        Name         = $name
        CommandTypes = [int]$ctRaw
        IsDummy      = $isDummy
        IsReal       = $isReal
        TypeName     = $typeName
      }
    }
    $enumerator.Dispose()
  } catch {
    Write-Warning "Get-CacheContents: cache inspection failed (non-fatal): $_"
  }
}

function Get-CacheStats {
  <#
  .SYNOPSIS
    Returns summary statistics about the PSScriptAnalyzer CommandInfoCache.

  .DESCRIPTION
    Returns a PSCustomObject with TotalEntries, RealCount, DummyCount, and UniqueNames.
    Always returns a non-null result — use directly without @() wrapper.
  #>
  [CmdletBinding()]
  [OutputType([System.Management.Automation.PSObject])]
  param()

  $contents = @(Get-CacheContents)
  $total = $contents.Count
  $realCount = @($contents | Where-Object { $_.IsReal }).Count
  $dummyCount = @($contents | Where-Object { $_.IsDummy }).Count
  $uniqueNames = @($contents | ForEach-Object { $_.Name } | Sort-Object -Unique).Count

  return [PSCustomObject]@{
    TotalEntries = $total
    RealCount    = $realCount
    DummyCount   = $dummyCount
    UniqueNames  = $uniqueNames
  }
}

function Assert-CacheEntry {
  <#
  .SYNOPSIS
    Asserts that a specific cache entry exists with the expected kind.

  .PARAMETER Name
    The command name to match.

  .PARAMETER CommandTypes
    The numeric CommandTypes value to match (e.g., 74 or 383).

  .PARAMETER ExpectedKind
    The expected entry type: Real (CmdletInfo/FunctionInfo), Dummy (RemoteCommandInfo),
    or Any (either kind, just verify existence).

  .DESCRIPTION
    Throws a detailed error message on mismatch — does NOT throw on success.
    Use this in test assertions to fail the test on unexpected cache state.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$CommandTypes,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Real', 'Dummy', 'Any')]
    [string]$ExpectedKind
  )

  $contents = @(Get-CacheContents)
  $matching = @($contents | Where-Object { $_.Name -eq $Name -and $_.CommandTypes -eq $CommandTypes })

  if ($matching.Count -eq 0) {
    throw "Assert-CacheEntry: entry not found - Name='$Name', CommandTypes=$CommandTypes (expected kind: $ExpectedKind)"
  }

  if ($ExpectedKind -eq 'Real' -and -not $matching[0].IsReal) {
    throw "Assert-CacheEntry: expected Real entry for Name='$Name', CommandTypes=$CommandTypes but got TypeName=$($matching[0].TypeName)"
  }

  if ($ExpectedKind -eq 'Dummy' -and -not $matching[0].IsDummy) {
    throw "Assert-CacheEntry: expected Dummy entry for Name='$Name', CommandTypes=$CommandTypes but got TypeName=$($matching[0].TypeName)"
  }
}

function Get-DiagnosticComparison {
  <#
  .SYNOPSIS
    Compares diagnostics across 3 cache states: baseline, warmup-only, full injection.

  .DESCRIPTION
    Runs Invoke-ScriptAnalyzer in 3 modes within a single session and compares
    the diagnostic output for equality. Returns a PSCustomObject with the comparison
    results.

    Mode A (Baseline): No cache manipulation — PSSA's natural cache state.
    Mode B (Warmup): Initialize-PSScriptAnalyzerCache (warmup only) before analysis.
    Mode C (Full injection): Initialize-PSScriptAnalyzerCache -InjectDummies before analysis.

    The comparison uses composite keys (ScriptName|Line|Column|RuleName|Severity|Message)
    for deep equality. Empty diff arrays mean the modes produced identical diagnostics.

    Requires PSScriptAnalyzer module imported and NUCLEUS_TEST_ROOT environment
    variable set (to locate optimize-pssa-cache.ps1 for the cache helper script).

  .PARAMETER TargetFile
    Path to the .ps1 file to analyze.

  .PARAMETER SettingsFile
    Path to the PSScriptAnalyzer settings file (.psd1).

  .PARAMETER NoInjection
    When set, skips Mode C (full injection) and only compares baseline vs warmup.
    Useful for isolating warmup effects.

  .EXAMPLE
    $result = Get-DiagnosticComparison -TargetFile "tests/scripts/cache-verify-lib.ps1" -SettingsFile "scripts/PSScriptAnalyzerSettings.psd1"
    $result.BaselineVsInjectionDiff.Count  # 0 when identical
  #>
  [CmdletBinding()]
  [OutputType([System.Management.Automation.PSObject])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetFile,

    [Parameter(Mandatory = $true)]
    [string]$SettingsFile,

    [Parameter()]
    [switch]$NoInjection
  )

  # Helper: build a composite key from a diagnostic object
  function Get-DiagnosticKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
      [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
      [object]$Diagnostic
    )
    process {
      "$($Diagnostic.ScriptName)|$($Diagnostic.Line)|$($Diagnostic.Column)|$($Diagnostic.RuleName)|$($Diagnostic.Severity)|$($Diagnostic.Message)"
    }
  }

  # Check PSSA availability
  if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Write-Warning "Get-DiagnosticComparison: PSScriptAnalyzer module not imported"
    return [PSCustomObject]@{
      BaselineCount           = -1
      WarmupCount             = -1
      InjectionCount          = -1
      BaselineVsWarmupDiff    = @()
      BaselineVsInjectionDiff = @()
      BaselineDiagnostics     = @()
      WarmupDiagnostics       = @()
      InjectionDiagnostics    = @()
    }
  }

  # Dot-source the cache helper script if available
  $repoRoot = $env:NUCLEUS_TEST_ROOT
  if ($repoRoot) {
    $cacheScript = Join-Path -Path $repoRoot -ChildPath "src/scripts/shell/optimize-pssa-cache.ps1"
    if (Test-Path -LiteralPath $cacheScript) {
      . $cacheScript
    }
  }

  # Mode A: Baseline — no cache manipulation
  $baselineDiags = @(Invoke-ScriptAnalyzer -Path $TargetFile -Settings $SettingsFile)

  # Mode B: Warmup-only — pre-populate via file analysis (no injection)
  $null = Initialize-PSScriptAnalyzerCache -Files @($TargetFile) -SettingsFile $SettingsFile
  $warmupDiags = @(Invoke-ScriptAnalyzer -Path $TargetFile -Settings $SettingsFile)

  # Mode C: Full injection — add dummy entries before analysis
  if (-not $NoInjection) {
    $null = Initialize-PSScriptAnalyzerCache -Files @($TargetFile) -SettingsFile $SettingsFile -InjectDummies
  }
  $injectionDiags = @(Invoke-ScriptAnalyzer -Path $TargetFile -Settings $SettingsFile)

  # Build composite key arrays for comparison
  $baselineKeys = @($baselineDiags | Get-DiagnosticKey)
  $warmupKeys = @($warmupDiags | Get-DiagnosticKey)
  $injectionKeys = @($injectionDiags | Get-DiagnosticKey)

  # Compare baseline vs warmup
  $bVsWDiff = @(if ($baselineKeys.Count -eq $warmupKeys.Count) {
    Compare-Object -ReferenceObject $baselineKeys -DifferenceObject $warmupKeys
  } else {
    [PSCustomObject]@{ SideIndicator = '=>'; InputObject = "Count mismatch: baseline=$($baselineKeys.Count) vs warmup=$($warmupKeys.Count)" }
  })

  # Compare baseline vs injection
  $bVsIDiff = @(if ($baselineKeys.Count -eq $injectionKeys.Count) {
    Compare-Object -ReferenceObject $baselineKeys -DifferenceObject $injectionKeys
  } else {
    [PSCustomObject]@{ SideIndicator = '=>'; InputObject = "Count mismatch: baseline=$($baselineKeys.Count) vs injection=$($injectionKeys.Count)" }
  })

  return [PSCustomObject]@{
    BaselineCount           = $baselineKeys.Count
    WarmupCount             = $warmupKeys.Count
    InjectionCount          = $injectionKeys.Count
    BaselineVsWarmupDiff    = $bVsWDiff
    BaselineVsInjectionDiff = $bVsIDiff
    BaselineDiagnostics     = $baselineDiags
    WarmupDiagnostics       = $warmupDiags
    InjectionDiagnostics    = $injectionDiags
  }
}
