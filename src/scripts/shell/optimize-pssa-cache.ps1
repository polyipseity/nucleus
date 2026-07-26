<#
.SYNOPSIS
  Pre-populates PSScriptAnalyzer's internal CommandInfo cache to speed up linting.

.DESCRIPTION
  PSScriptAnalyzer's AvoidAlias (PSAvoidUsingCmdletAliases) rule calls
  GetCommandInfo for every unique command name found in the target files, with
  two different CommandTypes values (74 = Function|Cmdlet|Filter and 383 = All).
  Each call resolves via Get-Command, which is slow (~60s per file for a large
  repo). By pre-populating the cache with lightweight RemoteCommandInfo dummy
  objects, the rule avoids actual Get-Command calls and runs in <100ms per file.

  This function:
  1. Runs a trivial Invoke-ScriptAnalyzer warmup ('1+1') to trigger PSSA's lazy
     initialization (Helper singleton, CommandInfoCache, RunspacePool).
  2. If the -Workaround parameter includes 'CachePrePopulation', reflects into
     the internal cache and inserts dummy RemoteCommandInfo entries for every
     command name found in the target files, for both key types (74 and 383).

  The warmup is REQUIRED before cache injection: the RunspacePool must be
  initialized for RemoteCommandInfo dummies to be traversable without
  NullReferenceException.

.PARAMETER Files
  Array of .ps1 file paths to scan for command names.

.PARAMETER SettingsFile
  Path to the PSScriptAnalyzer settings .psd1 file used for the warmup invocation.

.PARAMETER Workaround
  One or more workaround identifiers to apply. Default: @('CachePrePopulation').
  'CachePrePopulation' injects RemoteCommandInfo dummies for both CommandTypes
  keys (74 and 383). An empty array skips injection (warmup only).

.EXAMPLE
  $result = Initialize-PSScriptAnalyzerCache -Files $fileList -SettingsFile $settingsPath

.EXAMPLE
  $result = Initialize-PSScriptAnalyzerCache -Files $fileList -SettingsFile $settingsPath -Workaround @()

.NOTES
  Magic numbers:
  - 74 = CommandTypes value for Function|Cmdlet|Filter — hardcoded in AvoidAlias IL
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

    [string[]]$Workaround = @('CachePrePopulation')
  )

  $injectedNameCount = 0
  $diagnosticCount = 0
  try {
    # Warmup: trigger PSSA's internal lazy initialization (Helper singleton,
    # CommandInfoCache, RunspacePool). Required before cache injection because
    # the RunspacePool must be initialized for RemoteCommandInfo dummies to be
    # traversable without NullReferenceException.
    $null = Invoke-ScriptAnalyzer -ScriptDefinition '1+1' -Settings $SettingsFile

    if ($Workaround -contains 'CachePrePopulation') {
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
      # 74 = Function|Cmdlet|Filter — hardcoded in AvoidAlias IL (ldc.i4.s 74 at offset 0x1F)
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

      # Collect unique command names across all target files
      $allNames = [System.Collections.Generic.HashSet[string]]::new()
      foreach ($f in $Files) {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        $cmdNames = $fileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
          ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        foreach ($n in $cmdNames) {
          $null = $allNames.Add($n)
          # AvoidAlias checks both the raw name and Get-<name> for non-Get- commands
          if ($n -notlike 'Get-*') { $null = $allNames.Add("Get-$n") }
        }
      }

      # Inject dummy RemoteCommandInfo entries for both key types AvoidAlias uses
      foreach ($n in $allNames) {
        $ci = $remoteCtor.Invoke(@($n, [System.Management.Automation.CommandTypes]::Cmdlet))
        $lazy = $lazyCtor.Invoke(@($ci))

        # Insert with key type 74 (Function|Cmdlet|Filter)
        $k1 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k1, $n)
        $ctField.SetValue($k1, $nullableCmdlet)
        $null = $dict.TryAdd($k1, $lazy)

        # Insert with key type 383 (All)
        $k2 = [Activator]::CreateInstance($keyType)
        $nameField.SetValue($k2, $n)
        $ctField.SetValue($k2, $nullableAll)
        $null = $dict.TryAdd($k2, $lazy)
      }
      $injectedNameCount = $allNames.Count
    }
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

# Rule-to-workaround mapping: maps rule names to the workaround they require.
# Rules not in this map run without any workaround.
$script:RuleWorkaroundMap = @{
    'PSAvoidUsingCmdletAliases' = 'CachePrePopulation'
}
