<#
.SYNOPSIS
  Pre-populates PSScriptAnalyzer's internal CommandInfo cache to speed up linting.

.DESCRIPTION
  PSScriptAnalyzer's AvoidAlias (PSAvoidUsingCmdletAliases) rule calls
  GetCommandInfo for every unique command name found in the target files, with
  two different CommandTypes values (74 = Function|Cmdlet|Script and 383 = All).
  Each call resolves via Get-Command, which is slow (~60s per file for a large
  repo). By pre-populating the cache with lightweight RemoteCommandInfo dummy
  objects (or real CommandInfo objects from Get-Command), the rule avoids
  actual Get-Command calls and runs in <100ms per file.

  This function:
  1. Runs a trivial Invoke-ScriptAnalyzer warmup ('1+1') to trigger PSSA's lazy
     initialization (Helper singleton, CommandInfoCache, RunspacePool).
  2. If -RealCommandMap is provided with entries, injects real CommandInfo
     objects for matched command names (from Get-MatchingRealCommands).
  3. If -InjectDummies is set, injects all command names — real objects from
     -RealCommandMap for matched names, RemoteCommandInfo dummies for the rest.

  The warmup is REQUIRED before cache injection: the RunspacePool must be
  initialized for RemoteCommandInfo dummies to be traversable without
  NullReferenceException.

  When neither -RealCommandMap (non-empty) nor -InjectDummies is provided,
  runs warmup only — no injection.

.PARAMETER Files
  Array of .ps1 file paths to scan for command names.

.PARAMETER SettingsFile
  Path to the PSScriptAnalyzer settings .psd1 file used for the warmup invocation.

.PARAMETER CommandNames
  Pre-parsed command names to inject. When non-empty, skips internal file
  parsing. Used by the hybrid flow (check-pwsh.ps1) where
  Get-UniqueCommandNames has already been called externally.

.PARAMETER RealCommandMap
  Hashtable of name → real CommandInfo objects (CmdletInfo, FunctionInfo)
  from Get-MatchingRealCommands. When provided with entries, matched names
  inject the real object from the map. Default: $null (no real-object
  injection). When combined with -InjectDummies, matched names use the real
  object and unmatched names get RemoteCommandInfo dummies.

.PARAMETER InjectDummies
  Switch. When set, injects all parsed command names into the cache.
  Names present in -RealCommandMap inject the real CommandInfo object;
  all others inject a RemoteCommandInfo dummy. Must only be used for rules
  whose cache hit pattern is existence-only (e.g., PSAvoidUsingCmdletAliases
  which resolves aliases to commands). Rules that inspect CommandInfo
  metadata (Parameters, ParameterSets) must never use -InjectDummies.

.EXAMPLE
  $result = Initialize-PSScriptAnalyzerCache -Files $fileList -SettingsFile $settingsPath -InjectDummies

.EXAMPLE
  $result = Initialize-PSScriptAnalyzerCache -Files $fileList -SettingsFile $settingsPath -RealCommandMap $realMap

.EXAMPLE
  $result = Initialize-PSScriptAnalyzerCache -Files $fileList -SettingsFile $settingsPath
  # Warmup only (no injection)

.NOTES
  Magic numbers:
  - 74 = CommandTypes value for Function|Cmdlet|Script — hardcoded in AvoidAlias IL
    (ldc.i4.s 74 at IL offset 0x1F).
  - 383 = CommandTypes value for All — used when AvoidAlias calls GetCommandInfo
    with a null nullable parameter.

  This is a performance optimization. If the cache pre-population fails (e.g.
  due to a PSScriptAnalyzer version change that alters the internal structure),
  the function catches the error and writes a warning. Linting continues using
  the uncached Get-Command path.

  Dependencies: PSScriptAnalyzer module must be imported before calling this function.
  RunspacePool must be initialized (triggered by the internal warmup).
#>
function Initialize-PSScriptAnalyzerCache {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Files,

    [Parameter(Mandatory = $true)]
    [string]$SettingsFile,

    # Pre-parsed command names to inject. When non-empty, skips internal file
    # parsing. Used by the hybrid flow (check-pwsh.ps1) where
    # Get-UniqueCommandNames has already been called externally.
    [string[]]$CommandNames = @(),

    # Hashtable of name → real CommandInfo objects (CmdletInfo, FunctionInfo)
    # from Get-MatchingRealCommands. When provided with entries, matched names
    # inject the real object from the map. Default: $null.
    [hashtable]$RealCommandMap = $null,

    # When set, injects all parsed command names into the cache. Matched names
    # from -RealCommandMap inject real objects; all others inject
    # RemoteCommandInfo dummies. Only for existence-only rules.
    [switch]$InjectDummies
  )

  $injectedNameCount = 0
  $diagnosticCount = 0
  try {
    # Warmup: trigger PSSA's internal lazy initialization (Helper singleton,
    # CommandInfoCache, RunspacePool). Required before cache injection because
    # the RunspacePool must be initialized for RemoteCommandInfo dummies to be
    # traversable without NullReferenceException.
    $null = Invoke-ScriptAnalyzer -ScriptDefinition '1+1' -Settings $SettingsFile

    $hasRealMap = $RealCommandMap -and $RealCommandMap.Count -gt 0
    $shouldInject = $InjectDummies -or $hasRealMap
    if (-not $shouldInject) {
      # Warmup only — no injection requested (no -InjectDummies, no non-empty
      # -RealCommandMap). Return early to avoid reflective overhead.
      return [PSCustomObject]@{
        InjectedNameCount = 0
        DiagnosticCount = 0
      }
    }

    # Reflective access to Helper.Instance._commandInfoCacheLazy.Value._commandInfoCache
    $helperType = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Helper]
    $helper = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Helper]::Instance
    $cacheLazy = $helperType.GetField('_commandInfoCacheLazy', [System.Reflection.BindingFlags]'NonPublic,Instance').GetValue($helper)
    $cmdInfoCache = $cacheLazy.GetType().GetProperty('Value').GetValue($cacheLazy)
    $dictField = $cmdInfoCache.GetType().GetField('_commandInfoCache', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $dict = $dictField.GetValue($cmdInfoCache)

    # CommandLookupKey is a non-public nested struct with Name (string) and CommandTypes fields
    $keyType = ($cmdInfoCache.GetType().GetNestedTypes('NonPublic') | Where-Object { $_.Name -eq 'CommandLookupKey' })[0]
    $ctField = $keyType.GetField('CommandTypes', 'NonPublic,Instance')
    $nameField = $keyType.GetField('Name', 'NonPublic,Instance')

    # AvoidAlias calls GetCommandInfo with Nullable<CommandTypes> values
    $getCmdInfo = $helperType.GetMethod('GetCommandInfo')
    $paramType = $getCmdInfo.GetParameters()[1].ParameterType
    $underlyingType = $paramType.GetGenericArguments()[0]
    # 74 = Function|Cmdlet|Script — hardcoded in AvoidAlias IL (ldc.i4.s 74 at offset 0x1F)
    $cmdletVal = [System.Enum]::ToObject($underlyingType, 74)
    # 383 = All — used when nullable CommandTypes parameter is null
    $allVal = [System.Enum]::ToObject($underlyingType, 383)
    $nullableCmdlet = [Activator]::CreateInstance($paramType, [System.Object[]]@($cmdletVal))
    $nullableAll = [Activator]::CreateInstance($paramType, [System.Object[]]@($allVal))

    # Pre-create Lazy<CommandInfo> and RemoteCommandInfo constructors for injection
    $lazyType = [System.Lazy`1].MakeGenericType([System.Management.Automation.CommandInfo])
    $lazyCtor = $lazyType.GetConstructor(@([System.Management.Automation.CommandInfo]))
    $remoteType = [System.Management.Automation.RemoteCommandInfo]
    $remoteCtor = $remoteType.GetConstructor([System.Reflection.BindingFlags]'NonPublic,Instance', $null, @([string], [System.Management.Automation.CommandTypes]), $null)

    # Determine the names to inject — use pre-parsed $CommandNames if provided,
    # otherwise fall back to file parsing.
    if ($CommandNames -and $CommandNames.Count -gt 0) {
      $namesToInject = $CommandNames
    } else {
      $parsedNames = [System.Collections.Generic.HashSet[string]]::new()
      foreach ($f in $Files) {
        if (-not (Test-Path -Path $f)) { continue }
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        $cmdNames = $fileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
          ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        foreach ($n in $cmdNames) {
          $null = $parsedNames.Add($n)
          # AvoidAlias checks both the raw name and Get-<name> for non-Get- commands
          if ($n -notlike 'Get-*') { $null = $parsedNames.Add("Get-$n") }
        }
      }
      $namesToInject = $parsedNames
    }

    $injectedCount = 0

    if ($InjectDummies) {
      # Inject all names: use real object from map if available, otherwise
      # RemoteCommandInfo dummy. Unmatched names in the map are injected as
      # real objects (they were resolved by Get-MatchingRealCommands and exist
      # in the current session).
      foreach ($n in $namesToInject) {
        $ci = if ($hasRealMap -and $RealCommandMap.ContainsKey($n)) { $RealCommandMap[$n] } else { $remoteCtor.Invoke(@($n, [System.Management.Automation.CommandTypes]::Cmdlet)) }
        $lazy = $lazyCtor.Invoke(@($ci))

        # Insert with key type 74 (Function|Cmdlet|Script)
        $k1 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k1, $n)
        $ctField.SetValue($k1, $nullableCmdlet)
        $null = $dict.TryAdd($k1, $lazy)

        # Insert with key type 383 (All)
        $k2 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k2, $n)
        $ctField.SetValue($k2, $nullableAll)
        $null = $dict.TryAdd($k2, $lazy)

        $injectedCount++
      }
    } elseif ($hasRealMap) {
      # Inject only names present in RealCommandMap as real CommandInfo objects.
      # Unmatched names are skipped — they get natural cache population from
      # PSSA's Get-Command calls during rule evaluation.
      foreach ($n in $namesToInject) {
        if (-not $RealCommandMap.ContainsKey($n)) { continue }
        $ci = $RealCommandMap[$n]
        $lazy = $lazyCtor.Invoke(@($ci))

        # Insert with key type 74 (Function|Cmdlet|Script)
        $k1 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k1, $n)
        $ctField.SetValue($k1, $nullableCmdlet)
        $null = $dict.TryAdd($k1, $lazy)

        # Insert with key type 383 (All)
        $k2 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k2, $n)
        $ctField.SetValue($k2, $nullableAll)
        $null = $dict.TryAdd($k2, $lazy)

        $injectedCount++
      }
    }
    $injectedNameCount = $injectedCount
  } catch {
    # Injection is a performance optimization; failure is non-fatal.
    # Linting continues using the uncached Get-Command path.
    Write-Warning "CommandInfoCache pre-population failed (non-fatal): $_"
  }

  return [PSCustomObject]@{
    InjectedNameCount = $injectedNameCount
    DiagnosticCount = $diagnosticCount
  }
}
