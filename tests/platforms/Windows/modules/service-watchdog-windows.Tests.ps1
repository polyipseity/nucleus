<#
.SYNOPSIS
  Pester tests for the Windows service watchdog's prefix-match handling.

.DESCRIPTION
  Covers per-instance monitoring of a prefix-match registry entry and the
  once-per-transition report for a mount the user registry declares but Windows
  does not run. Function definitions are extracted from service-watchdog.ps1
  with the AST parser so the loop body can be driven with mocked hosts.

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
  Import-Module (Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Format-NucleusOutput.psm1') -Force -DisableNameChecking

  # The instance helpers are exercised by Get-NucleusServiceInstance.Tests.ps1;
  # here they are stubs so the loop can be driven from a fixed instance set.
  # The Windows cmdlets are also stubbed on non-Windows hosts, where they do not
  # exist and Pester would otherwise have nothing to Mock.
  # WHY: the stubs declare the parameters the watchdog passes so a Mock body can
  # read them by name; a parameterless stub makes Pester's own $Name win.
  $stubs = @{
    'Get-NucleusPrefixInstanceList'     = 'param([hashtable]$HostEntry)'
    'Get-NucleusConfiguredInstanceList' = 'param([hashtable]$HostEntry, [string]$Username, [string]$RepoRoot)'
    'Get-ScheduledTask'                 = 'param([string]$TaskPath, [string]$TaskName)'
    'Start-ScheduledTask'               = 'param([string]$TaskPath, [string]$TaskName)'
    'Stop-ScheduledTask'                = 'param([string]$TaskPath, [string]$TaskName)'
    'Get-Service'                       = 'param([string]$Name)'
    'Restart-Service'                   = 'param([string]$Name, [switch]$Force)'
  }
  foreach ($name in $stubs.Keys) {
    if (-not (Get-Command -Name $name -ErrorAction Ignore)) {
      Set-Item -Path "Function:$name" -Value ([scriptblock]::Create("$($stubs[$name])`nthrow 'stub: override with Mock'"))
    }
  }

  $Script:MarkerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("watchdog-test-{0}" -f [guid]::NewGuid().ToString('N'))
  $Script:MarkerDir = Join-Path (Join-Path $Script:MarkerRoot 'nucleus') 'state\service-stats'
  $env:ProgramData = $Script:MarkerRoot
  $Script:RepoRoot = 'C:\nucleus'
  $Script:MountEntry = @{ type = 'schtask'; prefixMatch = $true; service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount'; scope = 'user' }
}

AfterAll {
  if (Test-Path -Path $Script:MarkerRoot) { Remove-Item -Path $Script:MarkerRoot -Recurse -Force }
}

Describe 'Invoke-WatchdogIteration with a prefix-match entry' {
  BeforeEach {
    $Script:Started = @()
    $Script:Stopped = @()
    # Each case starts from a clean marker directory: the markers are what make
    # the not-loaded report once-per-transition rather than once-per-iteration.
    if (Test-Path -Path $Script:MarkerDir) { Remove-Item -Path $Script:MarkerDir -Recurse -Force }
    Mock Get-ScheduledTask { return @() }
    Mock Start-ScheduledTask { $Script:Started += $TaskName }
    Mock Stop-ScheduledTask { $Script:Stopped += $TaskName }
    Mock Get-NucleusConfiguredInstanceList { return @() }
    Mock Get-NucleusPrefixInstanceList { return @() }
    $Script:Services = @(
      @{
        key = 'cloud-drive'; displayName = 'Cloud Drive Mounts'; type = 'schtask'
        service = 'NucleusCloudMount-'; taskPath = '\NucleusCloudMount'
        prefixMatch = $true; hostEntry = $Script:MountEntry
      }
    )
  }

  It 'leaves a live instance running' {
    Mock Get-NucleusPrefixInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-iCloud') }
    Mock Get-ScheduledTask { return [PSCustomObject]@{ TaskName = 'NucleusCloudMount-iCloud'; TaskPath = '\NucleusCloudMount\'; State = 'Running' } }

    Invoke-WatchdogIteration > $null

    $Script:Started.Count | Should -Be 0
    $Script:Stopped.Count | Should -Be 0
  }

  It 'restarts a stuck instance of the entry' {
    Mock Get-NucleusPrefixInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-iCloud') }
    Mock Get-ScheduledTask { return [PSCustomObject]@{ TaskName = 'NucleusCloudMount-iCloud'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' } }

    Invoke-WatchdogIteration > $null

    $Script:Started | Should -Be @('NucleusCloudMount-iCloud')
    $Script:Stopped | Should -Be @('NucleusCloudMount-iCloud')
  }

  It 'reports a declared mount that Windows does not run' {
    Mock Get-NucleusConfiguredInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-OneDrive') }

    $output = Invoke-WatchdogIteration

    ($output -join "`n") | Should -Match 'cloud-drive .*configured but not loaded'
    (Get-NotLoadedMarkerPath -InstanceId '\NucleusCloudMount\NucleusCloudMount-OneDrive') | Should -Exist
  }

  It 'reports a declared mount only once per transition' {
    Mock Get-NucleusConfiguredInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-OneDrive') }

    $first = Invoke-WatchdogIteration
    $second = Invoke-WatchdogIteration

    @($first).Count | Should -Be 1
    @($second).Count | Should -Be 0
  }

  It 'clears the marker once the declared mount is live' {
    Mock Get-NucleusConfiguredInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-OneDrive') }
    Invoke-WatchdogIteration > $null
    (Get-NotLoadedMarkerPath -InstanceId '\NucleusCloudMount\NucleusCloudMount-OneDrive') | Should -Exist

    Mock Get-NucleusPrefixInstanceList { return @('\NucleusCloudMount\NucleusCloudMount-OneDrive') }
    Mock Get-ScheduledTask { return [PSCustomObject]@{ TaskName = 'NucleusCloudMount-OneDrive'; TaskPath = '\NucleusCloudMount\'; State = 'Running' } }
    Invoke-WatchdogIteration > $null

    (Get-NotLoadedMarkerPath -InstanceId '\NucleusCloudMount\NucleusCloudMount-OneDrive') | Should -Not -Exist
    $Script:Started.Count | Should -Be 0
  }

  It 'stays silent when nothing is live and nothing is declared' {
    $output = Invoke-WatchdogIteration

    @($output).Count | Should -Be 0
    @(Get-ChildItem -Path $Script:MarkerDir -Filter '*.notloaded' -ErrorAction Ignore).Count | Should -Be 0
  }
}

Describe 'Invoke-WatchdogIteration with plain entries' {
  BeforeEach {
    $Script:Restarted = @()
    if (Test-Path -Path $Script:MarkerDir) { Remove-Item -Path $Script:MarkerDir -Recurse -Force }
    Mock Restart-Service { $Script:Restarted += $Name }
    Mock Get-NucleusPrefixInstanceList { return @() }
    Mock Get-NucleusConfiguredInstanceList { return @() }
    Mock Start-ScheduledTask { }
    $Script:Services = @(
      @{ key = 'ollama'; displayName = 'Ollama'; type = 'native'; service = 'ollama'; prefixMatch = $false; hostEntry = @{ type = 'native'; service = 'ollama' } }
    )
  }

  It 'restarts a stopped native service' {
    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Stopped' } }

    Invoke-WatchdogIteration > $null

    $Script:Restarted | Should -Be @('ollama')
  }

  It 'leaves a running native service alone' {
    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Running' } }

    Invoke-WatchdogIteration > $null

    $Script:Restarted.Count | Should -Be 0
  }
}
