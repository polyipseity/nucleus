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

function Get-CacheStats {
  <#
  .SYNOPSIS
    Returns summary statistics about the PSScriptAnalyzer CommandInfoCache.

  .DESCRIPTION
    Returns a PSCustomObject with TotalEntries, RealCount, DummyCount, and UniqueNames.
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

  $contents = Get-CacheContents
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

  # For Any, any entry is fine — just existence was checked above.
}
