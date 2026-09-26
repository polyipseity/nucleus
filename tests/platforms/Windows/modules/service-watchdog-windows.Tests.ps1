<#
.SYNOPSIS
  Pester tests for the Windows service watchdog's rule table.

.DESCRIPTION
  Covers the rule order shared with the POSIX watchdog
  (src/scripts/services/service-watchdog.sh):  disabled, blocked, looping,
  broken, and not-live handling, plus prefix-match instance expansion.

  The watchdog's function definitions are extracted from service-watchdog.ps1
  with the AST parser, so the iteration body can be driven from a fixed service
  set.  The health record is exercised for real against a per-run temporary
  storage root, so the rules run against the same record shape production uses;
  only Get-HealthBootId (which reads WMI) and the supervisor interface are mocked.
  Adapter behaviour is covered by supervisor-scm.Tests.ps1 and
  supervisor-schtask.Tests.ps1.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/service-watchdog-windows.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $watchdogPath = Join-Path $PSScriptRoot '../../../../src/scripts/services/service-watchdog.ps1'
  $watchdogContent = Get-Content -Path $watchdogPath -Raw
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($watchdogContent, [ref]$tokens, [ref]$errors)
  $functionAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  . ([scriptblock]::Create(($functionAsts | ForEach-Object { $_.Extent.Text }) -join "`n"))

  # Get-NucleusCommandName lives in the shared output module the watchdog imports.
  $Script:ModulesDir = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules'
  Import-Module (Join-Path $Script:ModulesDir 'Format-NucleusOutput.psm1') -Force -DisableNameChecking
  . (Join-Path $Script:ModulesDir 'ServiceHealth.ps1')

  # The health record is under test, so point the storage root at a per-run
  # temporary directory instead of the real per-user one.
  $Script:SavedLocalAppData = $env:LOCALAPPDATA
  $Script:StateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("watchdog-health-{0}" -f [guid]::NewGuid().ToString('N'))
  $env:LOCALAPPDATA = $Script:StateRoot

  # The supervisor interface is stubbed so the rule table is driven from
  # explicit primitives.  Import-SupervisorAdapter itself is left as extracted
  # and neutralised with Mock in the rule describes, so the real adapters (which
  # re-declare the same eight names) never load underneath the stubs.
  # WHY: the stubs declare the parameters the watchdog passes so a Mock body can
  # read them by name; a parameterless stub makes Pester's own $Name win.
  $stubs = @{
    'Supervisor-Enabled'                = 'param([string]$Target)'
    'Supervisor-Live'                   = 'param([string]$Target)'
    'Supervisor-Generation'             = 'param([string]$Target)'
    'Supervisor-LastExit'               = 'param([string]$Target)'
    'Supervisor-Start'                  = 'param([string]$Target)'
    'Supervisor-Stop'                   = 'param([string]$Target)'
    'Supervisor-Repair'                 = 'param([string]$Target)'
    'Get-NucleusPrefixInstanceList'     = 'param([hashtable]$HostEntry)'
    'Get-NucleusConfiguredInstanceList' = 'param([hashtable]$HostEntry, [string]$Username, [string]$RepoRoot)'
  }
  foreach ($name in $stubs.Keys) {
    Set-Item -Path "Function:$name" -Value ([scriptblock]::Create("$($stubs[$name])`nthrow 'stub: override with Mock'"))
  }
}

AfterAll {
  $env:LOCALAPPDATA = $Script:SavedLocalAppData
  if (Test-Path -Path $Script:StateRoot) { Remove-Item -Path $Script:StateRoot -Recurse -Force }
}

Describe 'Invoke-WatchdogIteration rule table' {
  BeforeEach {
    # Every test starts from an empty health store so records do not leak.
    $stateDir = Join-Path $Script:StateRoot 'nucleus'
    if (Test-Path -Path $stateDir) { Remove-Item -Path $stateDir -Recurse -Force }

    $Script:Started = @()
    $Script:Stopped = @()
    $Script:Repaired = @()

    Mock Import-SupervisorAdapter { }
    Mock Get-HealthBootId { return 'test-boot' }
    Mock Supervisor-Enabled { return $true }
    Mock Supervisor-Live { return $true }
    Mock Supervisor-Generation { return 0 }
    Mock Supervisor-LastExit { return 0 }
    Mock Supervisor-Start { $Script:Started += $Target }
    Mock Supervisor-Stop { $Script:Stopped += $Target }
    Mock Invoke-BoundedRepair { $Script:Repaired += $Target; return 0 }
    Mock Get-NucleusPrefixInstanceList { return @() }
    Mock Get-NucleusConfiguredInstanceList { return @() }

    $Script:Services = @(
      @{
        key = 'ollama'; displayName = 'Ollama'; type = 'windows-native'
        service = 'ollama'; taskPath = $null; prefixMatch = $false
        hostEntry = @{ type = 'windows-native'; service = 'ollama' }
      }
    )
  }

  It 'rule 1: leaves a disabled service alone' {
    Mock Supervisor-Enabled { return $false }

    Invoke-WatchdogIteration > $null

    $Script:Started.Count | Should -Be 0
    $Script:Stopped.Count | Should -Be 0
    $Script:Repaired.Count | Should -Be 0
  }

  It 'rule 2: reports a blocked record once and never revives it' {
    Set-HealthBlocked -Instance 'ollama' -Class 'mount-failed' -Remedy 'check the remote'

    $first = @(Invoke-WatchdogIteration)
    $second = @(Invoke-WatchdogIteration)

    ($first -join "`n") | Should -BeLike '*is blocked (mount-failed)*'
    $second.Count | Should -Be 0
    $Script:Started.Count | Should -Be 0
  }

  It 'rule 3: blocks and stops a looping service' {
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    Initialize-HealthRecord -Instance 'ollama'
    Set-HealthField -Instance 'ollama' -Field 'restarts' -Value @($now, $now, $now, $now, $now, $now, $now, $now, $now, $now)

    Invoke-WatchdogIteration > $null

    (Get-HealthField -Instance 'ollama' -Field 'state') | Should -Be 'blocked'
    (Get-HealthField -Instance 'ollama' -Field 'class') | Should -Be 'crash-loop'
    $Script:Stopped | Should -Be @('ollama')
    $Script:Started.Count | Should -Be 0
  }

  It 'rule 4: repairs a live service that exited with EX_CONFIG' {
    Mock Supervisor-LastExit { return 78 }

    Invoke-WatchdogIteration > $null

    $Script:Repaired | Should -Be @('ollama')
    $Script:Stopped.Count | Should -Be 0
    $Script:Started.Count | Should -Be 0
  }

  It 'rule 5: starts a service that is not live and not blocked' {
    Mock Supervisor-Live { return $false }

    Invoke-WatchdogIteration > $null

    $Script:Started | Should -Be @('ollama')
    $Script:Repaired.Count | Should -Be 0
  }

  It 'adopts the generation token as a baseline on first observation' {
    # WHY: the first tick must not read the supervisor's current run as a
    # restart, or every cold start would immediately look like a crash loop.
    Mock Supervisor-Generation { return 1234 }
    Mock Supervisor-LastExit { return 3 }

    Invoke-WatchdogIteration > $null

    (Get-HealthField -Instance 'ollama' -Field 'generation') | Should -Be 1234
    (Get-HealthField -Instance 'ollama' -Field 'lastExit') | Should -Be 3
    @(Get-HealthField -Instance 'ollama' -Field 'restarts').Count | Should -Be 0
    (Get-HealthField -Instance 'ollama' -Field 'state') | Should -Not -Be 'blocked'
  }

  It 'stamps a success when the generation token is unchanged across a tick' {
    Mock Supervisor-Generation { return 42 }

    Invoke-WatchdogIteration > $null
    Set-HealthField -Instance 'ollama' -Field 'lastSuccess' -Value 0

    Invoke-WatchdogIteration > $null

    @(Get-HealthField -Instance 'ollama' -Field 'restarts').Count | Should -Be 0
    (Get-HealthField -Instance 'ollama' -Field 'lastSuccess') | Should -BeGreaterThan 0
  }

  It 'counts a restart when the generation token moves backwards' {
    # A process-id token is not monotonic: it can fall to zero and later jump to
    # a new pid.  Comparing with '>' would miss the drop, so a loop that only
    # ever moved the token downwards would never be flagged.
    Initialize-HealthRecord -Instance 'ollama'
    Set-HealthField -Instance 'ollama' -Field 'generation' -Value 1234

    Mock Supervisor-Generation { return 0 }
    Invoke-WatchdogIteration > $null
    @(Get-HealthField -Instance 'ollama' -Field 'restarts').Count | Should -Be 1

    Mock Supervisor-Generation { return 5678 }
    Invoke-WatchdogIteration > $null
    @(Get-HealthField -Instance 'ollama' -Field 'restarts').Count | Should -Be 2
  }

  It 'blocks a service that keeps restarting, detected from the generation token alone' {
    # The restarts array is never seeded here: this is the production detection
    # path, where the only signal is the supervisor's generation token
    # advancing.  A crash loop never survives a tick, so five changed ticks trip
    # the consecutive-failure rule and the instance is blocked, not restarted.
    # Only the change between ticks matters, so a counter advances the token on
    # every observation instead of six literal per-tick return values.
    $Script:GenerationToken = 0
    Mock Supervisor-Generation { return ($Script:GenerationToken += 1) }
    Invoke-WatchdogIteration > $null
    Invoke-WatchdogIteration > $null
    Invoke-WatchdogIteration > $null
    Invoke-WatchdogIteration > $null
    Invoke-WatchdogIteration > $null
    Invoke-WatchdogIteration > $null

    (Get-HealthField -Instance 'ollama' -Field 'state') | Should -Be 'blocked'
    (Get-HealthField -Instance 'ollama' -Field 'class') | Should -Be 'crash-loop'
    $Script:Stopped | Should -Be @('ollama')
    $Script:Started.Count | Should -Be 0
  }

  It 'stays silent when nothing is declared' {
    $Script:Services = @()

    $output = Invoke-WatchdogIteration

    @($output).Count | Should -Be 0
  }
}

Describe 'Invoke-WatchdogIteration with a prefix-match entry' {
  BeforeEach {
    $stateDir = Join-Path $Script:StateRoot 'nucleus'
    if (Test-Path -Path $stateDir) { Remove-Item -Path $stateDir -Recurse -Force }

    $Script:Started = @()
    $Script:Stopped = @()

    Mock Import-SupervisorAdapter { }
    Mock Get-HealthBootId { return 'test-boot' }
    Mock Supervisor-Enabled { return $true }
    Mock Supervisor-Live { return $true }
    Mock Supervisor-Generation { return 0 }
    Mock Supervisor-LastExit { return 0 }
    Mock Supervisor-Start { $Script:Started += $Target }
    Mock Supervisor-Stop { $Script:Stopped += $Target }
    Mock Invoke-BoundedRepair { return 0 }
    Mock Get-NucleusPrefixInstanceList { return @() }
    Mock Get-NucleusConfiguredInstanceList { return @() }

    $Script:Services = @(
      @{
        key = 'cloud-drive'; displayName = 'Cloud Drive Mounts'; type = 'windows-schtask'
        service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount'; prefixMatch = $true
        hostEntry = @{ type = 'windows-schtask'; prefixMatch = $true; service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount' }
      }
    )
  }

  It 'checks every declared instance on its own' {
    Mock Get-NucleusPrefixInstanceList {
      return @('\NucleusCloudMount\NucleusCloudMount-iCloud', '\NucleusCloudMount\NucleusCloudMount-GoogleDrive')
    }
    Mock Supervisor-Live { return $Target -eq '\NucleusCloudMount\NucleusCloudMount-iCloud' }

    Invoke-WatchdogIteration > $null

    $Script:Started | Should -Be @('\NucleusCloudMount\NucleusCloudMount-GoogleDrive')
    $Script:Stopped.Count | Should -Be 0
  }

  It 'leaves a live instance running' {
    Mock Get-NucleusPrefixInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-iCloud') }

    Invoke-WatchdogIteration > $null

    $Script:Started.Count | Should -Be 0
    $Script:Stopped.Count | Should -Be 0
  }

  It 'reports an instance that is configured but not loaded once' {
    Mock Supervisor-Enabled { return $false }
    Mock Get-NucleusConfiguredInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-iCloud') }

    $first = @(Invoke-WatchdogIteration)
    $second = @(Invoke-WatchdogIteration)

    ($first -join "`n") | Should -BeLike '*configured but not loaded*'
    $second.Count | Should -Be 0
    (Get-HealthField -Instance '\NucleusCloudMount\NucleusCloudMount-iCloud' -Field 'state') | Should -Be 'not-loaded'
  }

  It 'refuses to revive an instance whose record still says not-loaded' {
    # WHY driven rather than injected: the POSIX suite (service-watchdog-tests.sh
    # Section 5) rejects fabricating the record because that only proves Rule 4b
    # can read a state nothing in production wrote.  Tick 1 therefore runs the
    # production writer (Rule 1 -> Write-NotLoadedNotice) and only then does tick
    # 2 ask what Rule 4b does with the record it left behind.
    $live = '\NucleusCloudMount\NucleusCloudMount-iCloud'
    Mock Get-NucleusPrefixInstanceList { return @($live) }
    Mock Get-NucleusConfiguredInstanceList { return @($live) }

    # Tick 1: the supervisor does not have the unit yet.
    Mock Supervisor-Enabled { return $false }
    Invoke-WatchdogIteration > $null
    (Get-HealthField -Instance $live -Field 'state') | Should -Be 'not-loaded'

    # Tick 2: the unit appeared without nucleus-apply clearing the record.
    Mock Supervisor-Enabled { return $true }
    Mock Supervisor-Live { return $false }
    Invoke-WatchdogIteration > $null

    # Rule 4b reads the record, not the probe: only nucleus-apply re-arms it.
    $Script:Started.Count | Should -Be 0
    (Get-HealthField -Instance $live -Field 'state') | Should -Be 'not-loaded'
  }

  It 'blocks and stops an instance that is looping' {
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $live = '\NucleusCloudMount\NucleusCloudMount-iCloud'
    Initialize-HealthRecord -Instance $live
    Set-HealthField -Instance $live -Field 'restarts' -Value @($now, $now, $now, $now, $now, $now, $now, $now, $now, $now)

    Mock Get-NucleusPrefixInstanceList { return @($live) }

    Invoke-WatchdogIteration > $null

    (Get-HealthField -Instance $live -Field 'state') | Should -Be 'blocked'
    $Script:Stopped | Should -Be @($live)
    $Script:Started.Count | Should -Be 0
  }
}

Describe 'Import-SupervisorAdapter' {
  BeforeEach {
    # The real adapter must load here, so this describe drives the extracted
    # function directly instead of mocking it as the rule describes do.
    $script:LoadedSupervisorKind = $null
  }

  It 'loads the SCM adapter for the native kind' {
    Import-SupervisorAdapter -Kind 'scm'

    (Supervisor-Kind) | Should -Be 'scm'
  }

  It 'loads the scheduled-task adapter for the schtask kind' {
    Import-SupervisorAdapter -Kind 'schtask'

    (Supervisor-Kind) | Should -Be 'schtask'
  }

  It 'rejects an unknown kind' {
    { Import-SupervisorAdapter -Kind 'nope' } | Should -Throw '*no supervisor adapter for kind*'
  }
}

Describe 'Get-SupervisorKindForType' {
  It 'maps the two supervisor-driven Windows types' {
    (Get-SupervisorKindForType -Type 'windows-native') | Should -Be 'scm'
    (Get-SupervisorKindForType -Type 'windows-schtask') | Should -Be 'schtask'
  }

  It 'returns nothing for a type no supervisor drives' {
    (Get-SupervisorKindForType -Type 'omitted') | Should -BeNullOrEmpty
  }
}

Describe 'Invoke-BoundedRepair' {
  # WHY this exists: the rule table can no longer reach this wrapper (it is
  # mocked there so the parent's decision is observable), so the wrapper's own
  # contract is pinned here against the real child job.
  It 'throws when no supervisor adapter is loaded' {
    $script:LoadedSupervisorKind = $null
    { Invoke-BoundedRepair -Target 'ollama' -TimeoutSeconds 5 } |
      Should -Throw '*no supervisor adapter is loaded'
  }

  It 'returns 1 when the repair ran and failed' {
    $script:LoadedSupervisorKind = 'scm'
    $rc = Invoke-BoundedRepair -Target 'nucleus-no-such-service' -TimeoutSeconds 60
    $rc | Should -Be 1
  }
}
