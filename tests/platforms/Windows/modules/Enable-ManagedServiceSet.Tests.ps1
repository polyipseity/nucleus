<#
.SYNOPSIS
  Pester tests for the registry-driven Windows service enable gate.

.DESCRIPTION
  Covers the pre-DSC enable pass and the post-convergence repair. A fixture
  module holds the production functions and the Windows cmdlets they call, so
  every case mocks inside that module instead of touching host state.

  Run with: pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests/platforms/Windows/modules/Enable-ManagedServiceSet.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $modulePath = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Enable-ManagedServiceSet.ps1'
  $Script:FixtureModuleName = 'EnableManagedServiceSetFixture'
  $Script:RegistryPath = Join-Path $TestDrive 'services.json'
  $Script:MarkerPath = Join-Path $TestDrive 'apply-continued.marker'

  $fixtureRegistry = @{
    '$schema' = './services.schema.json'
    '$logging' = @{
      Windows = @{ logDir = 'x'; systemLogDir = 'y' }
    }
    'plain-native' = @{
      displayName = 'Plain native'
      hosts       = @{ Windows = @{ type = 'windows-native'; service = 'nucleus-plain'; scope = 'system' } }
    }
    'plain-task' = @{
      displayName = 'Plain task'
      hosts       = @{ Windows = @{ type = 'windows-schtask'; taskPath = '\NucleusPlain'; scope = 'user' } }
    }
    'omitted-native' = @{
      displayName = 'Omitted native'
      hosts       = @{ Windows = @{ type = 'omitted' } }
    }
    'mount-family' = @{
      displayName = 'Cloud mounts'
      hosts       = @{
        Windows = @{
          type        = 'windows-schtask'
          prefixMatch = $true
          service     = 'NucleusCloudMount-'
          taskPath    = '\NucleusCloudMount'
          scope       = 'user'
        }
      }
    }
  }
  $fixtureRegistry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Script:RegistryPath -Encoding utf8

  $fixtureModule = New-Module -Name $Script:FixtureModuleName -ScriptBlock {
    param([string]$Path)

    $Script:FixtureRegistryPath = ''
    $Script:FixtureMarkerPath = ''
    $Script:FixtureTasks = @()
    $Script:FixtureService = $null
    $Script:FixtureCimService = $null
    $Script:FixtureProbeError = ''

    function Set-FixtureState {
      <#
      .SYNOPSIS
        Sets the fixture inputs read by the stubbed Windows cmdlets.
      #>
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test-only fixture setter; no host state changes
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      [CmdletBinding()]
      param(
        [string]$RegistryPath = $Script:FixtureRegistryPath,
        [string]$MarkerPath = $Script:FixtureMarkerPath,
        [object[]]$Tasks = $Script:FixtureTasks,
        [object]$Service = $Script:FixtureService,
        [object]$CimService = $Script:FixtureCimService,
        [string]$ProbeError = $Script:FixtureProbeError
      )

      $Script:FixtureRegistryPath = $RegistryPath
      $Script:FixtureMarkerPath = $MarkerPath
      $Script:FixtureTasks = @($Tasks)
      $Script:FixtureService = $Service
      $Script:FixtureCimService = $CimService
      $Script:FixtureProbeError = $ProbeError
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) { . $Path }

    function Set-Service {
      # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- stub throws; Mock supplies behavior
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$Name, [string]$StartupType)
      throw 'stub: Set-Service'
    }
    function Start-Service {
      # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- stub throws; Mock supplies behavior
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- Name binds Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$Name)
      throw 'stub: Start-Service'
    }
    function Enable-ScheduledTask {
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$TaskPath, [string]$TaskName)
      throw 'stub: Enable-ScheduledTask'
    }
    function Start-ScheduledTask {
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- stub throws; Mock supplies behavior
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$TaskPath, [string]$TaskName)
      throw 'stub: Start-ScheduledTask'
    }
    function Get-ScheduledTask {
      [CmdletBinding()]
      [OutputType([object[]])]
      param([string]$TaskPath, [string]$TaskName)
      if ($PSBoundParameters.ContainsKey('TaskName')) {
        if ($Script:FixtureProbeError -eq 'task-missing') {
          Write-Error "No scheduled task named '$TaskName' matched the probe"
          return
        }
        if ($Script:FixtureProbeError -eq 'task-failure') {
          throw [System.InvalidOperationException]::new('task probe failed')
        }
        return @($Script:FixtureTasks | Where-Object { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath })
      }
      return @($Script:FixtureTasks)
    }
    function Get-Service {
      # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
      [CmdletBinding()]
      param([string]$Name)
      if ($Script:FixtureProbeError -eq 'service') { throw [System.InvalidOperationException]::new('service probe failed') }
      if ($null -eq $Script:FixtureService) {
        throw [System.Management.Automation.ItemNotFoundException]::new("Cannot find service '$Name'")
      }
      return $Script:FixtureService
    }
    function Get-CimInstance {
      # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$ClassName, [string]$Filter)
      return $Script:FixtureCimService
    }
    function Set-NucleusService {
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- stub throws; Mock supplies behavior
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      [CmdletBinding()]
      param([string]$Name, [string]$BinaryPath, [string]$DisplayName, [string]$StartType)
      throw 'stub: Set-NucleusService'
    }
    function Get-NucleusConfiguredInstanceList {
      [CmdletBinding()]
      [OutputType([object[]])]
      # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params mirror the production resolver signature
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
      param([hashtable]$HostEntry, [string]$Username, [string]$RepoRoot)
      return @('\NucleusCloudMount\NucleusCloudMount-configured')
    }

    # Supervisor-* functions from the scheduler adapter are not part of this fixture's surface.
    Export-ModuleMember -Function Enable-ManagedServiceSet, Repair-ManagedServiceSet, Set-FixtureState
  } -ArgumentList $modulePath

  Import-Module $fixtureModule -Force

  $Script:DefaultTasks = @(
    [pscustomobject]@{
      TaskName = 'NucleusPlain'
      TaskPath = '\'
      State    = 'Ready'
      Settings = [pscustomobject]@{ Enabled = $true }
    }
    [pscustomobject]@{
      TaskName = 'NucleusCloudMount-iCloud'
      TaskPath = '\NucleusCloudMount'
      State    = 'Ready'
      Settings = [pscustomobject]@{ Enabled = $true }
    }
  )

  Set-FixtureState -RegistryPath $Script:RegistryPath -MarkerPath $Script:MarkerPath -Tasks $Script:DefaultTasks
}
AfterAll {
  Remove-Module $Script:FixtureModuleName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup -- the fixture may not be loaded when a case fails early
}

Describe 'Enable-ManagedServiceSet pre-DSC pass' {
  BeforeEach {
    Set-FixtureState -Tasks $Script:DefaultTasks -Service $null -CimService $null -ProbeError ''
    if (Test-Path -LiteralPath $Script:MarkerPath) { Remove-Item -LiteralPath $Script:MarkerPath -Force }
  }

  It 'enables a windows-native service by startup type and never starts it' {
    InModuleScope $Script:FixtureModuleName {
      Mock Set-Service { }
      Mock Enable-ScheduledTask { }
      Mock Start-Service { }

      $cleared = @(Enable-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows')

      $cleared | Should -Contain 'plain-native'
      Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'nucleus-plain' -and $StartupType -eq 'Automatic' }
      Should -Invoke Start-Service -Times 0
    }
  }

  It 'enables a windows-schtask entry and never starts it' {
    InModuleScope $Script:FixtureModuleName {
      Mock Set-Service { }
      Mock Enable-ScheduledTask { }
      Mock Start-ScheduledTask { }

      $cleared = @(Enable-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows')

      $cleared | Should -Contain 'plain-task'
      Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' -and $TaskName -eq 'NucleusPlain' }
      Should -Invoke Start-ScheduledTask -Times 0
    }
  }

  It 'skips omitted host entries and configured-only prefix instances' {
    InModuleScope $Script:FixtureModuleName {
      Mock Set-Service { }
      Mock Enable-ScheduledTask { }

      $cleared = @(Enable-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows')

      $cleared | Should -Not -Contain 'omitted-native'
      $cleared | Should -Not -Contain '\NucleusCloudMount\NucleusCloudMount-configured'
      Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'nucleus-plain' }
      Should -Invoke Enable-ScheduledTask -Times 2 -Exactly -ParameterFilter { $TaskName -ne 'NucleusCloudMount-configured' }
    }
  }

  It 'enables one live prefix instance per scheduled task' {
    InModuleScope $Script:FixtureModuleName {
      Mock Set-Service { }
      Mock Enable-ScheduledTask { }

      $cleared = @(Enable-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows')

      $cleared | Should -Contain '\NucleusCloudMount\NucleusCloudMount-iCloud'
      Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\NucleusCloudMount' -and $TaskName -eq 'NucleusCloudMount-iCloud' }
    }
  }

  It 'throws on a real enable failure and prevents the apply continuation marker' {
    InModuleScope $Script:FixtureModuleName {
      Mock Set-Service { throw [System.InvalidOperationException]::new('Access denied') }
      Mock Enable-ScheduledTask { }

      $continued = $false
      try {
        $null = Enable-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows'
        $continued = $true
        Set-Content -LiteralPath $Script:FixtureMarkerPath -Value 'continued'
      } catch {
        $Script:FixtureErrorMessage = $_.Exception.Message
      }

      $continued | Should -BeFalse
      $Script:FixtureErrorMessage | Should -Match 'Access denied'
      Test-Path -LiteralPath $Script:FixtureMarkerPath | Should -BeFalse
    }
  }
}

Describe 'Repair-ManagedServiceSet after convergence' {
  BeforeEach {
    Set-FixtureState -Tasks $Script:DefaultTasks -Service $null -CimService $null -ProbeError ''
  }

  It 're-enables a PowerShell-registered task family after re-registration' {
    $disabledTasks = @(
      [pscustomobject]@{
        TaskName = 'NucleusCloudMount-iCloud'
        TaskPath = '\NucleusCloudMount'
        State    = 'Disabled'
        Settings = [pscustomobject]@{ Enabled = $false }
      }
    )
    Set-FixtureState -Tasks $disabledTasks

    InModuleScope $Script:FixtureModuleName {
      Mock Enable-ScheduledTask { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('\NucleusCloudMount\NucleusCloudMount-iCloud')

      Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\NucleusCloudMount' -and $TaskName -eq 'NucleusCloudMount-iCloud' }
    }
  }

  It 'leaves an already loaded task alone' {
    InModuleScope $Script:FixtureModuleName {
      Mock Enable-ScheduledTask { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-task')

      Should -Invoke Enable-ScheduledTask -Times 0
    }
  }

  It 'bootstraps a cleared native service that is not loaded' {
    Set-FixtureState -Service ([pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' }) -CimService ([pscustomobject]@{ PathName = 'C:\bin\nucleus-plain.exe' })

    InModuleScope $Script:FixtureModuleName {
      Mock Set-NucleusService { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-native')

      Should -Invoke Set-NucleusService -Times 1 -Exactly -ParameterFilter { $Name -eq 'nucleus-plain' -and $BinaryPath -eq 'C:\bin\nucleus-plain.exe' -and $StartType -eq 'Automatic' }
    }
  }

  It 'does not act on a loaded native service' {
    Set-FixtureState -Service ([pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }) -CimService ([pscustomobject]@{ PathName = 'C:\bin\nucleus-plain.exe' })

    InModuleScope $Script:FixtureModuleName {
      Mock Set-NucleusService { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-native')

      Should -Invoke Set-NucleusService -Times 0
    }
  }

  It 'acts on a target only once when the same id is passed twice' {
    Set-FixtureState -Service ([pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' }) -CimService ([pscustomobject]@{ PathName = 'C:\bin\nucleus-plain.exe' })

    InModuleScope $Script:FixtureModuleName {
      Mock Set-NucleusService { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-native', 'plain-native')

      Should -Invoke Set-NucleusService -Times 1 -Exactly
    }
  }

  It 'accepts an empty cleared list without acting on anything' {
    InModuleScope $Script:FixtureModuleName {
      Mock Enable-ScheduledTask { }
      Mock Set-NucleusService { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @()

      Should -Invoke Enable-ScheduledTask -Times 0
      Should -Invoke Set-NucleusService -Times 0
    }
  }

  It 'throws when the loaded-state probe fails' {
    Set-FixtureState -ProbeError 'service'

    InModuleScope $Script:FixtureModuleName {
      Mock Set-NucleusService { }

      { Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-native') } |
        Should -Throw '*service probe failed*'
      Should -Invoke Set-NucleusService -Times 0
    }
  }

  It 'enables a missing scheduled task when the probe uses an unexpected absence message' {
    Set-FixtureState -Tasks @() -ProbeError 'task-missing'

    InModuleScope $Script:FixtureModuleName {
      Mock Enable-ScheduledTask { }

      Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-task')

      Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' -and $TaskName -eq 'NucleusPlain' }
    }
  }

  It 'throws on a scheduled-task probe failure without enabling anything' {
    Set-FixtureState -Tasks $Script:DefaultTasks -ProbeError 'task-failure'

    InModuleScope $Script:FixtureModuleName {
      Mock Enable-ScheduledTask { }

      { Repair-ManagedServiceSet -RegistryPath $Script:FixtureRegistryPath -HostKey 'Windows' -Targets @('plain-task') } |
        Should -Throw '*task probe failed*'
      Should -Invoke Enable-ScheduledTask -Times 0
    }
  }
}

Describe 'svc.ps1 wiring' {
  It 'loads the shared filter before calling it' {
    # The AST-extraction suite does not execute svc.ps1's load block, so a source
    # order check is the guard against calling the filter before it is defined.
    $svcPath = Join-Path $PSScriptRoot '../../../../scripts/svc.ps1'
    $svcText = Get-Content -LiteralPath $svcPath -Raw
    $loadAt = $svcText.IndexOf('modules\Enable-ManagedServiceSet.ps1')
    $callAt = $svcText.IndexOf('Get-NucleusHostServiceEntries -RegistryRaw')

    $loadAt | Should -BeGreaterThan -1
    $callAt | Should -BeGreaterThan $loadAt
  }
}

Describe 'Windows apply wiring' {
  It 'repairs cleared services after the last service-mutating Sync call and before post-apply' {
    # Sync-WindowsRDP stops TermService when RDP parity is off, so a repair
    # above it would leave a cleared target stopped in a -NoSystemParity run.
    $applyPath = Join-Path $PSScriptRoot '../../../../src/hosts/Windows/apply.ps1'
    $applyText = Get-Content -LiteralPath $applyPath -Raw
    $rdpAt = $applyText.IndexOf('Sync-WindowsRDP -Enabled:')
    $repairAt = $applyText.IndexOf('Repair-ManagedServiceSet -RegistryPath')
    $postApplyAt = $applyText.IndexOf('Invoke-PostApply -RepoRoot')

    $rdpAt | Should -BeGreaterThan -1
    $repairAt | Should -BeGreaterThan $rdpAt
    $postApplyAt | Should -BeGreaterThan $repairAt
  }
}
