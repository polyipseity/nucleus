<#
.SYNOPSIS
  Pester tests for svc.ps1 internal functions.

.DESCRIPTION
  Tests the Format-StatusTable, Resolve-ServiceName, Get-ServiceStatus,
  and Invoke-ServiceAction functions by sourcing the function definitions
  from svc.ps1 with a mock $Registry.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/svc-windows.Tests.ps1 -Passthru"
#>

BeforeAll {
  # Read svc.ps1 and extract function definitions using the PowerShell AST parser.
  # This handles nested braces correctly, unlike simple regex approaches.
  $svcPs1Path = Join-Path $PSScriptRoot '../../../../scripts/svc.ps1'
  $svcPs1Content = Get-Content -Path $svcPs1Path -Raw
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($svcPs1Content, [ref]$tokens, [ref]$errors)

  # Extract all function definitions from the AST.
  $functionAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  $functionCode = ($functionAsts | ForEach-Object { $_.Extent.Text }) -join "`n"

  # Script-scoped mock Registry (models the filtered structure from svc.ps1 main logic).
  $Script:Registry = @{
    'ollama' = @{
      displayName = 'Ollama'
      description = 'LLM inference server'
      network     = @{ default = @{ host = '127.0.0.1'; port = 11434; protocol = 'http' } }
      hostEntry   = @{ type = 'native'; service = 'ollama' }
    }
    'sshd' = @{
      displayName = 'SSH Server'
      description = 'Remote shell access via SSH'
      network     = @{ default = @{ host = '0.0.0.0'; port = 22; protocol = 'tcp' } }
      hostEntry   = @{ type = 'native'; service = 'sshd' }
    }
    'cloud-drive' = @{
      displayName = 'Cloud Drive Mounts'
      description = 'rclone FUSE cloud drive mounts'
      hostEntry   = @{ type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'NucleusCloudMount-' }
    }
    'camilladsp' = @{
      displayName = 'CamillaDSP'
      description = 'Audio processor'
      network     = @{ websocket = @{ host = '127.0.0.1'; port = 1234; protocol = 'tcp' } }
      hostEntry   = @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
    }
  }

  # Script-scoped mock RegistryRaw (raw JSON structure before main processing).
  $Script:RegistryRaw = @{
    'ollama' = @{
      displayName = 'Ollama'
      description = 'LLM inference server'
      network     = @{ default = @{ host = '127.0.0.1'; port = 11434; protocol = 'http' } }
      hosts       = @{ Windows = @{ platform = 'Windows'; type = 'native'; service = 'ollama'; logging = @{ capture = 'all' } } }
      logging     = @{ maxSize = 10000000 }
    }
    'sshd' = @{
      displayName = 'SSH Server'
      description = 'Remote shell access via SSH'
      network     = @{ default = @{ host = '0.0.0.0'; port = 22; protocol = 'tcp' } }
      hosts       = @{ Windows = @{ platform = 'Windows'; type = 'native'; service = 'sshd' } }
    }
    'cloud-drive' = @{
      displayName = 'Cloud Drive Mounts'
      description = 'rclone FUSE cloud drive mounts'
      hosts       = @{ Windows = @{ platform = 'Windows'; type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'NucleusCloudMount-'; logging = @{ capture = 'stderr' } } }
    }
    'camilladsp' = @{
      displayName = 'CamillaDSP'
      description = 'Audio processor'
      network     = @{ websocket = @{ host = '127.0.0.1'; port = 1234; protocol = 'tcp' } }
      hosts       = @{ Windows = @{ platform = 'Windows'; type = 'schtask'; taskPath = '\NucleusCamillaDSP' } }
    }
  }

  # Pester v5 cannot Mock commands that do not exist in the session (verified
  # empirically), so every mocked command absent from non-Windows CI hosts needs
  # a stub definition first — log-management helpers sourced by svc.ps1 and
  # Windows-only cmdlets. Each Mock below overrides its stub.
  function Get-NucleusLogDir { throw 'stub: Get-NucleusLogDir' }
  function Get-NucleusSystemLogDir { throw 'stub: Get-NucleusSystemLogDir' }
  # PSSA: these stubs intentionally shadow built-in cmdlets (Pester v5 cannot
  # Mock nonexistent commands) and are immediately replaced by Mock definitions;
  # the inline suppressions are scoped to each stub only.
  function Get-WinEvent {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    param()
    throw 'stub: Get-WinEvent'
  }
  function ConvertTo-SanitizedText { process { $_ } }
  function Get-ScheduledTask { throw 'stub: Get-ScheduledTask' }
  function Get-CimInstance {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    param()
    throw 'stub: Get-CimInstance'
  }
  function Get-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    param()
    throw 'stub: Get-Service'
  }
  function Start-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Start-Service'
  }
  function Stop-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Stop-Service'
  }
  function Restart-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Restart-Service'
  }
  # Params declared so Pester binds them for -ParameterFilter assertions.
  function Set-Service {
    # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- test stub shadows built-in cmdlet for Pester Mock
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- params bind Pester -ParameterFilter assertions
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param([string]$Name, [string]$StartupType, [string]$ErrorAction)
    throw 'stub: Set-Service'
  }
  # Write-Nucleus* helpers come from Format-NucleusOutput.psm1 (not dot-sourced
  # here); stub them to mirror production so Write-Error interception works.
  function Write-NucleusError { param([string]$Message) Write-Error "svc: error: $Message" }
  function Write-NucleusWarning { param([string]$Message) Write-Warning "svc: warning: $Message" }
  function Write-NucleusInfo { param([string]$CommandName, [string]$Message) Write-Information "svc: [$CommandName] $Message" }
  function Start-ScheduledTask {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Start-ScheduledTask'
  }
  function Stop-ScheduledTask {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test stub throws; Mock supplies behavior
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    throw 'stub: Stop-ScheduledTask'
  }
  function Enable-ScheduledTask { throw 'stub: Enable-ScheduledTask' }
  function Disable-ScheduledTask { throw 'stub: Disable-ScheduledTask' }

  # Mock external dependencies for log functions.
  Mock Get-NucleusLogDir { return 'TestDrive:\nucleus\logs' }
  Mock Get-NucleusSystemLogDir { return 'TestDrive:\nucleus\system-logs' }
  Mock Get-WinEvent { return @() }
  Mock ConvertTo-SanitizedText { process { $_ } }
  # Resolution enumerates scheduled tasks; an empty default keeps unrelated
  # tests order-independent (per-context Mocks replace it).
  Mock Get-ScheduledTask { return @() }

  # Script-scoped host (constant for Windows).
  $Script:NucleusHost = 'Windows'
  $NucleusHost = $Script:NucleusHost

  # Prefix-match instance resolution lives in its own module, mirroring
  # src/scripts/lib/svc-instances.sh on POSIX.
  . (Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Get-NucleusServiceInstance.ps1')

  # Dot-source the function definitions.
  . ([scriptblock]::Create($functionCode))
}

# ---------------------------------------------------------------------------
# Format-StatusTable
# ---------------------------------------------------------------------------

Describe 'Format-StatusTable' {
  It 'outputs table with headers and separator when Json is false' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'live'; id = 'ollama'; displayName = 'Ollama'; status = 'active'; running = $true; pid = 12345 }
      @{ class = 'live'; id = 'sshd'; displayName = 'SSH Server'; status = 'inactive'; running = $false; pid = $null }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Not -BeNullOrEmpty
    $output | Should -Match 'ID\s+Name\s+Status\s+Running\s+PID'
    $output | Should -Match 'ollama'
    $output | Should -Match '12345'
    $output | Should -Match 'inactive'
  }

  It 'outputs compressed JSON when Json is true' {
    $Script:Json = $true
    $rows = @(
      @{ class = 'live'; id = 'ollama'; displayName = 'Ollama'; status = 'active'; running = $true; pid = 12345 }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Not -BeNullOrEmpty
    $output | Should -Match '"version":1'
    $output | Should -Match '"services"'
    $output | Should -Match '"ollama"'
  }

  It 'omits error rows in JSON mode' {
    $Script:Json = $true
    $rows = @(
      @{ class = 'live'; id = 'ollama'; displayName = 'Ollama'; status = 'active'; running = $true; pid = 12345 }
      @{ class = 'error'; id = 'cloud-driv'; displayName = 'cloud-driv'; status = 'n/a'; running = '-'; pid = '-' }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Match '"ollama"'
    $output | Should -Not -Match 'cloud-driv'
  }

  It 'reports error rows as n/a under the requested name' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'error'; id = 'cloud-driv'; displayName = 'cloud-driv'; status = 'n/a'; running = '-'; pid = '-' }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Match 'cloud-driv'
    $output | Should -Match 'n/a'
    $output | Should -Not -Match 'unknown'
  }

  It 'reports pseudo rows as n/a instead of inactive' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'pseudo'; id = 'cloud-drive'; displayName = 'Cloud Drive Mounts'; status = 'n/a'; running = '-'; pid = '-' }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Match 'cloud-drive'
    $output | Should -Match 'n/a'
    $output | Should -Not -Match 'inactive'
  }

  It 'prints the instance id with its display name for instance rows' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'live'; id = '\NucleusCloudMount\NucleusCloudMount-work'; displayName = 'Cloud Drive Mounts (work)'; status = 'active'; running = $true; pid = 4321 }
    )
    $output = Format-StatusTable -Rows $rows
    $output | Should -Match 'Cloud Drive Mounts \(work\)'
    $output | Should -Match '4321'
  }

  It 'formats PID as "-" when pid is null' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'live'; id = 'sshd'; displayName = 'SSH Server'; status = 'inactive'; running = $false; pid = $null }
    )
    $output = Format-StatusTable -Rows $rows
    $lines = $output -split "`n"
    $dataLines = $lines | Where-Object { $_ -match 'sshd' }
    $dataLines | ForEach-Object { $_ | Should -Match '\s-\s*$' }
  }

  It 'formats PID as number when pid is present' {
    $Script:Json = $false
    $rows = @(
      @{ class = 'live'; id = 'ollama'; displayName = 'Ollama'; status = 'active'; running = $true; pid = 9876 }
    )
    $output = Format-StatusTable -Rows $rows
    $lines = $output -split "`n"
    $dataLines = $lines | Where-Object { $_ -match 'ollama' }
    $dataLines | ForEach-Object { $_ | Should -Match '9876' }
  }
}

# ---------------------------------------------------------------------------
# Resolve-ServiceName
# ---------------------------------------------------------------------------

Describe 'Resolve-ServiceName' {
  It 'resolves every registry entry when no names are given' {
    $resolved = @(Resolve-ServiceName -Names @())
    $resolved.instanceId | Should -Contain 'ollama'
    $resolved.instanceId | Should -Contain 'sshd'
    $resolved.instanceId | Should -Contain 'camilladsp'
  }

  It 'includes a prefix-match entry with no live instance as a pseudo row' {
    Mock Get-ScheduledTask { return @() }

    $resolved = @(Resolve-ServiceName -Names @('cloud-drive'))
    $resolved.instanceId | Should -Contain 'cloud-drive'
    $resolved.Count | Should -Be 1
    $resolved[0].class | Should -Be 'pseudo'
    $resolved[0].registryKey | Should -Be 'cloud-drive'
  }

  It 'returns a live row for a known service' {
    $resolved = @(Resolve-ServiceName -Names @('ollama'))
    $resolved.Count | Should -Be 1
    $resolved[0].class | Should -Be 'live'
    $resolved[0].instanceId | Should -Be 'ollama'
    $resolved[0].hostEntry.service | Should -Be 'ollama'
  }

  It 'returns an error row that carries the requested name' {
    $resolved = @(Resolve-ServiceName -Names @('nonexistent'))
    $resolved.Count | Should -Be 1
    $resolved[0].class | Should -Be 'error'
    $resolved[0].instanceId | Should -Be 'nonexistent'
    $resolved[0].displayName | Should -Be 'nonexistent'
    $resolved[0].hostEntry.error | Should -Be 'service not found in registry'
  }

  It 'resolves multiple services' {
    $resolved = @(Resolve-ServiceName -Names @('ollama', 'sshd'))
    $resolved.instanceId | Should -Contain 'ollama'
    $resolved.instanceId | Should -Contain 'sshd'
  }

  Context 'prefix expansion (schtask)' {
    It 'expands prefix-match with matching scheduled tasks' {
      Mock Get-ScheduledTask {
        return @(
          [PSCustomObject]@{ TaskName = 'NucleusCloudMount-work'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
        )
      }

      $resolved = @(Resolve-ServiceName -Names @('cloud-drive'))
      $resolved.Count | Should -Be 1
      $resolved[0].class | Should -Be 'live'
      $resolved[0].registryKey | Should -Be 'cloud-drive'
      $resolved[0].instanceId | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
      $resolved[0].displayName | Should -Be 'Cloud Drive Mounts (work)'
      $resolved[0].hostEntry.type | Should -Be 'schtask'
      $resolved[0].hostEntry.taskPath | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
    }

    It 'ignores tasks that do not match the prefix' {
      Mock Get-ScheduledTask {
        return @(
          [PSCustomObject]@{ TaskName = 'NucleusCloudMount-work'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
          [PSCustomObject]@{ TaskName = 'OtherTask'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
          [PSCustomObject]@{ TaskName = 'NucleusCamillaDSP'; TaskPath = '\'; State = 'Ready' }
        )
      }

      $resolved = @(Resolve-ServiceName -Names @('cloud-drive'))
      $resolved.Count | Should -Be 1
      $resolved[0].instanceId | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
    }

    It 'accepts a printed instance id as a service name' {
      Mock Get-ScheduledTask {
        return @(
          [PSCustomObject]@{ TaskName = 'NucleusCloudMount-work'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
        )
      }

      $resolved = @(Resolve-ServiceName -Names @('\NucleusCloudMount\NucleusCloudMount-work'))
      $resolved.Count | Should -Be 1
      $resolved[0].class | Should -Be 'live'
      $resolved[0].registryKey | Should -Be 'cloud-drive'
      $resolved[0].displayName | Should -Be 'Cloud Drive Mounts (work)'
    }

    It 'reports a mistyped instance id as an error naming the prefix' {
      Mock Get-ScheduledTask {
        return @(
          [PSCustomObject]@{ TaskName = 'NucleusCloudMount-work'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
        )
      }

      $resolved = @(Resolve-ServiceName -Names @('\NucleusCloudMount\NucleusCloudMount-nope'))
      $resolved.Count | Should -Be 1
      $resolved[0].class | Should -Be 'error'
      $resolved[0].instanceId | Should -Be '\NucleusCloudMount\NucleusCloudMount-nope'
      $resolved[0].hostEntry.error | Should -Match 'no such instance'
    }
  }
}

Describe 'New-StatusRow' {
  It 'reports non-live rows as n/a without probing' {
    Mock Get-ServiceStatus { throw 'Get-ServiceStatus must not be called' }

    $row = New-StatusRow -ResolvedRow @{ registryKey = 'cloud-drive'; displayName = 'Cloud Drive Mounts'; hostEntry = @{ prefixMatch = $true }; instanceId = 'cloud-drive'; class = 'pseudo' }
    $row.status | Should -Be 'n/a'
    $row.running | Should -Be '-'
    $row.pid | Should -Be '-'
    Should -Invoke Get-ServiceStatus -Exactly 0
  }

  It 'probes live rows and labels them with the instance id' {
    Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 42 } }

    $row = New-StatusRow -ResolvedRow @{ registryKey = 'cloud-drive'; displayName = 'Cloud Drive Mounts (work)'; hostEntry = @{ type = 'schtask'; taskPath = '\NucleusCloudMount\NucleusCloudMount-work' }; instanceId = '\NucleusCloudMount\NucleusCloudMount-work'; class = 'live' }
    $row.id | Should -Be '\NucleusCloudMount\NucleusCloudMount-work'
    $row.displayName | Should -Be 'Cloud Drive Mounts (work)'
    $row.status | Should -Be 'active'
    $row.class | Should -Be 'live'
  }
}

# ---------------------------------------------------------------------------
# Get-ServiceStatus
# ---------------------------------------------------------------------------

Describe 'Get-ServiceStatus' {
  Context 'native type' {
    It 'returns active status for running service' {
      Mock Get-Service {
        return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
      }
      Mock Get-CimInstance {
        return [PSCustomObject]@{ ProcessId = 12345 }
      }

      $status = Get-ServiceStatus -HostEntry @{ type = 'native'; service = 'ollama' }
      $status.status | Should -Be 'active'
      $status.running | Should -Be $true
      $status.enabled | Should -Be $true
    }

    It 'returns inactive status for stopped service' {
      Mock Get-Service {
        return [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' }
      }

      $status = Get-ServiceStatus -HostEntry @{ type = 'native'; service = 'sshd' }
      $status.status | Should -Be 'inactive'
      $status.running | Should -Be $false
      $status.enabled | Should -Be $false
    }

    It 'returns not-found when Get-Service throws' {
      Mock Get-Service { throw 'not found' }

      $status = Get-ServiceStatus -HostEntry @{ type = 'native'; service = 'nonexistent' }
      $status.status | Should -Be 'not-found'
      $status.running | Should -Be $false
    }
  }

  Context 'schtask type' {
    It 'returns active for running task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Running' }
      }

      $status = Get-ServiceStatus -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'active'
      $status.running | Should -Be $true
    }

    It 'returns inactive for ready task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Ready' }
      }

      $status = Get-ServiceStatus -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'inactive'
      $status.running | Should -Be $false
      $status.enabled | Should -Be $true
    }

    It 'returns disabled for disabled task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Disabled' }
      }

      $status = Get-ServiceStatus -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'disabled'
      $status.enabled | Should -Be $false
    }

    It 'returns not-found when Get-ScheduledTask throws' {
      Mock Get-ScheduledTask { throw 'not found' }

      $status = Get-ServiceStatus -HostEntry @{ type = 'schtask'; taskPath = '\Unknown' }
      $status.status | Should -Be 'not-found'
    }
  }

  Context 'unknown type' {
    It 'returns unknown status' {
      $status = Get-ServiceStatus -HostEntry @{ type = 'unsupported' }
      $status.status | Should -Be 'unknown'
      $status.error | Should -Match 'unsupported type'
    }
  }
}
# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

Describe 'Dispatch' {
  BeforeAll {
    # Extract the switch ($Action) dispatch statement from the svc.ps1 AST.
    $switchAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
    # Filter to the outermost switch ($Action) that contains 'list' (only the
    # top-level dispatch switch has it; the inner one in Invoke-ServiceAction
    # only has start/stop/restart/enable/disable/status).
    $dispatchSwitchAst = $switchAsts | Where-Object { $_.Condition.Extent.Text -eq '$Action' -and $_.Extent.Text -match "'list'" } | Select-Object -First 1
    $dispatchSwitchText = $dispatchSwitchAst.Extent.Text -replace '\bexit\b', 'throw'

    # Row builders for the Resolve-ServiceName Mocks (resolution returns rows).
    function New-TestRow {
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test helper builds an in-memory row
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      param(
        [string]$RegistryKey,
        [string]$DisplayName,
        [string]$InstanceId,
        [string]$Class,
        [hashtable]$HostEntry
      )
      return @{ registryKey = $RegistryKey; displayName = $DisplayName; hostEntry = $HostEntry; instanceId = $InstanceId; class = $Class }
    }

    function New-LiveRow {
      # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- test helper builds an in-memory row
      [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
      param([string]$Key = 'ollama')
      return New-TestRow -RegistryKey $Key -DisplayName $Key -InstanceId $Key -Class 'live' -HostEntry $Script:Registry[$Key].hostEntry
    }

    # Test helper that wraps the switch dispatch for testing.
    function Invoke-Dispatch {
      param(
        [string]$Action,
        [string[]]$ServiceName
      )
      # Parameters consumed by the dynamic switch dispatch below.
      Write-Debug "Invoke-Dispatch: Action=$Action ServiceName=$($ServiceName -join ',')"
      $Registry = $Script:Registry
      $RegistryRaw = $Script:RegistryRaw
      $NucleusHost = $Script:NucleusHost
      $Json = $Script:Json
      . ([scriptblock]::Create($dispatchSwitchText))
    }
  }

  BeforeEach {
    $Script:Json = $false
  }

  Context 'action routing' {
    It 'routes list to Resolve-ServiceName and Format-StatusTable' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345 } }
      Mock Format-StatusTable { return 'formatted' }

      Invoke-Dispatch -Action list

      Should -Invoke Resolve-ServiceName -Exactly 1
      Should -Invoke Format-StatusTable -Exactly 1
    }

    It 'routes status to Resolve-ServiceName and Format-StatusTable' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345 } }
      Mock Format-StatusTable { return 'formatted' }

      Invoke-Dispatch -Action status

      Should -Invoke Resolve-ServiceName -Exactly 1
      Should -Invoke Format-StatusTable -Exactly 1
    }

    It 'routes start to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action start -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'start' }
    }

    It 'routes stop to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action stop -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'stop' }
    }

    It 'routes restart to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action restart -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'restart' }
    }

    It 'routes enable to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action enable -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'enable' }
    }

    It 'routes disable to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action disable -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'disable' }
    }

    It 'routes endpoint and outputs endpoint URL' {
      Mock Get-Content { return '{"ollama":{"network":{"default":{"host":"127.0.0.1","port":11434,"protocol":"http"}}}}' }
      Mock ConvertFrom-Json {
        return [PSCustomObject]@{
          ollama = [PSCustomObject]@{
            network = [PSCustomObject]@{
              default = [PSCustomObject]@{ host = '127.0.0.1'; port = 11434; protocol = 'http' }
            }
          }
        }
      }

      $output = Invoke-Dispatch -Action endpoint -ServiceName @('ollama', 'default')
      $output | Should -Be 'http://127.0.0.1:11434'
    }

    It 'routes logs with service name to Show-ServiceLog' {
      Mock Show-ServiceLog { }

      Invoke-Dispatch -Action logs -ServiceName @('ollama')

      Should -Invoke Show-ServiceLog -Exactly 1 -ParameterFilter { $ServiceKey -eq 'ollama' }
    }

    It 'routes logs without service name to Show-ServiceList' {
      Mock Get-HostService { return @('ollama') }
      Mock Get-CaptureMode { return 'all' }
      Mock Test-ServiceHasLog { return $true }
      Mock Show-ServiceList { }

      Invoke-Dispatch -Action logs

      Should -Invoke Show-ServiceList -Exactly 1
    }

    It 'routes log-paths to Get-ServiceLogFile' {
      Mock Get-ServiceLogFile { return @() }

      Invoke-Dispatch -Action log-paths -ServiceName @('ollama')

      Should -Invoke Get-ServiceLogFile -Exactly 1 -ParameterFilter { $ServiceKey -eq 'ollama' }
    }

    It 'routes log-config to Show-LogConfig' {
      Mock Show-LogConfig { }

      Invoke-Dispatch -Action log-config -ServiceName @('ollama')

      Should -Invoke Show-LogConfig -Exactly 1 -ParameterFilter { $ServiceKey -eq 'ollama' -and -not $JsonOut }
    }
  }

  Context 'error handling' {
    It 'endpoint with no ServiceName throws' {
      { Invoke-Dispatch -Action endpoint } | Should -Throw 'missing service name for endpoint'
    }

    It "start with no ServiceName throws" {
      { Invoke-Dispatch -Action start } | Should -Throw "missing service name for 'start'"
    }

    It "stop with no ServiceName throws" {
      { Invoke-Dispatch -Action stop } | Should -Throw "missing service name for 'stop'"
    }

    It "restart with no ServiceName throws" {
      { Invoke-Dispatch -Action restart } | Should -Throw "missing service name for 'restart'"
    }

    It "enable with no ServiceName throws" {
      { Invoke-Dispatch -Action enable } | Should -Throw "missing service name for 'enable'"
    }

    It "disable with no ServiceName throws" {
      { Invoke-Dispatch -Action disable } | Should -Throw "missing service name for 'disable'"
    }

    It 'logs with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action logs -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc: error: unknown service*'
    }

    It 'log-paths with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action log-paths -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc: error: unknown service*'
    }

    It 'log-config with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action log-config -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc: error: unknown service*'
    }
  }

  Context 'JSON routing' {
    It 'list with Json outputs JSON through Format-StatusTable' {
      $Script:Json = $true
      Mock Resolve-ServiceName { return @(New-LiveRow -Key 'ollama') }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345; displayName = 'Ollama' } }

      $output = Invoke-Dispatch -Action list

      $output | Should -Match '"version":1'
    }

    It 'log-config with Json passes -JsonOut to Show-LogConfig' {
      $Script:Json = $true
      Mock Show-LogConfig { }

      Invoke-Dispatch -Action log-config -ServiceName @('ollama')

      Should -Invoke Show-LogConfig -Exactly 1 -ParameterFilter { $ServiceKey -eq 'ollama' -and $JsonOut }
    }
  }

  Context 'instance resolution' {
    It 'acts on one instance when given its printed id' {
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'cloud-drive' -DisplayName 'Cloud Drive Mounts (work)' -InstanceId '\NucleusCloudMount\NucleusCloudMount-work' -Class 'live' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCloudMount\NucleusCloudMount-work' })
      }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action restart -ServiceName @('\NucleusCloudMount\NucleusCloudMount-work')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'restart' -and $HostEntry.taskPath -eq '\NucleusCloudMount\NucleusCloudMount-work' }
    }

    It 'acts once per live instance when given the registry key' {
      Mock Resolve-ServiceName {
        return @(
          New-TestRow -RegistryKey 'cloud-drive' -DisplayName 'Cloud Drive Mounts (a)' -InstanceId '\NucleusCloudMount\NucleusCloudMount-a' -Class 'live' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCloudMount\NucleusCloudMount-a' }
          New-TestRow -RegistryKey 'cloud-drive' -DisplayName 'Cloud Drive Mounts (b)' -InstanceId '\NucleusCloudMount\NucleusCloudMount-b' -Class 'live' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCloudMount\NucleusCloudMount-b' }
        )
      }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action stop -ServiceName @('cloud-drive')

      Should -Invoke Invoke-ServiceAction -Exactly 2 -ParameterFilter { $Action -eq 'stop' }
    }

    It 'fails an action on a prefix-match key with no live instances' {
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'cloud-drive' -DisplayName 'Cloud Drive Mounts' -InstanceId 'cloud-drive' -Class 'pseudo' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'NucleusCloudMount-' })
      }
      Mock Invoke-ServiceAction { return $true }
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action restart -ServiceName @('cloud-drive') } | Should -Throw 'Write-Error: svc: error: cloud-drive — no instances found*'
      Should -Invoke Invoke-ServiceAction -Exactly 0
    }

    It 'warns and keeps going when the name is unknown' {
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'ERROR:cloud-driv' -DisplayName 'cloud-driv' -InstanceId 'cloud-driv' -Class 'error' -HostEntry @{ error = 'service not found in registry' })
      }
      Mock Write-NucleusWarning { }
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action start -ServiceName @('cloud-driv') } | Should -Throw 'Write-Error: svc: error: cloud-driv*'
      Should -Invoke Write-NucleusWarning -Exactly 0
    }

    It 'omits unknown targets from list JSON' {
      $Script:Json = $true
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'ERROR:cloud-driv' -DisplayName 'cloud-driv' -InstanceId 'cloud-driv' -Class 'error' -HostEntry @{ error = 'service not found in registry' })
      }

      $output = Invoke-Dispatch -Action list -ServiceName @('cloud-driv')

      $output | Should -Not -Match 'cloud-driv'
      $output | Should -Not -Match 'unknown'
    }

    It 'fails verify on an unknown service' {
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'ERROR:cloud-driv' -DisplayName 'cloud-driv' -InstanceId 'cloud-driv' -Class 'error' -HostEntry @{ error = 'service not found in registry' })
      }

      { Invoke-Dispatch -Action verify -ServiceName @('cloud-driv') } | Should -Throw
    }

    It 'does not fail verify when a prefix-match key has no instances' {
      Mock Resolve-ServiceName {
        return @(New-TestRow -RegistryKey 'cloud-drive' -DisplayName 'Cloud Drive Mounts' -InstanceId 'cloud-drive' -Class 'pseudo' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'NucleusCloudMount-' })
      }
      Mock Write-NucleusWarning { }

      Invoke-Dispatch -Action verify -ServiceName @('cloud-drive')

      Should -Invoke Write-NucleusWarning -Exactly 1 -ParameterFilter { $Message -match 'no instances found' }
    }
  }
}
# ---------------------------------------------------------------------------
# Invoke-ServiceAction
# ---------------------------------------------------------------------------

Describe 'Invoke-ServiceAction' {
  Context 'native type' {
    It 'starts a service and returns $true' {
      Mock Start-Service { }

      $result = Invoke-ServiceAction -Action 'start' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Start-Service -Exactly 1
    }

    It 'stops a service and returns $true' {
      Mock Stop-Service { }

      $result = Invoke-ServiceAction -Action 'stop' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Stop-Service -Exactly 1
    }

    It 'restarts a service and returns $true' {
      Mock Restart-Service { }

      $result = Invoke-ServiceAction -Action 'restart' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Restart-Service -Exactly 1
    }

    It 'enables a service and returns $true' {
      Mock Set-Service { }

      $result = Invoke-ServiceAction -Action 'enable' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Set-Service -Exactly 1 -ParameterFilter { $StartupType -eq 'Automatic' }
    }

    It 'disables a service and returns $true' {
      Mock Set-Service { }

      $result = Invoke-ServiceAction -Action 'disable' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Set-Service -Exactly 1 -ParameterFilter { $StartupType -eq 'Disabled' }
    }

    It 'returns status via Get-ServiceStatus' {
      Mock Get-Service {
        return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
      }
      Mock Get-CimInstance {
        return [PSCustomObject]@{ ProcessId = 12345 }
      }

      $result = Invoke-ServiceAction -Action 'status' -HostEntry @{ type = 'native'; service = 'ollama' }
      $result.status | Should -Be 'active'
    }
  }

  Context 'schtask type' {
    It 'starts a scheduled task and returns $true' {
      Mock Start-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'start' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Start-ScheduledTask -Exactly 1
    }

    It 'stops a scheduled task and returns $true' {
      Mock Stop-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'stop' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Stop-ScheduledTask -Exactly 1
    }

    It 'restarts a scheduled task (stop then start) and returns $true' {
      Mock Stop-ScheduledTask { }
      Mock Start-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'restart' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Stop-ScheduledTask -Exactly 1
      Should -Invoke Start-ScheduledTask -Exactly 1
    }

    It 'enables a scheduled task and returns $true' {
      Mock Enable-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'enable' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Enable-ScheduledTask -Exactly 1
    }

    It 'disables a scheduled task and returns $true' {
      Mock Disable-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'disable' -HostEntry @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Disable-ScheduledTask -Exactly 1
    }
  }

  Context 'unsupported type' {
    It 'throws for unsupported type' {
      { Invoke-ServiceAction -Action 'start' -HostEntry @{ type = 'unknown' } } | Should -Throw
    }
  }
}

# ---------------------------------------------------------------------------
# Log helper functions
# ---------------------------------------------------------------------------

Describe 'Get-HostService' {
  It 'returns sorted service names' {
    $result = Get-HostService
    $result.Count | Should -Be 4
    $result[0] | Should -Be 'camilladsp'
    $result[-1] | Should -Be 'sshd'
  }
}

Describe 'Get-CaptureMode' {
  It 'returns platform-specific capture mode when set' {
    $result = Get-CaptureMode -ServiceKey 'ollama'
    $result | Should -Be 'all'
  }

  It 'falls back to platform-specific when top-level not set' {
    $result = Get-CaptureMode -ServiceKey 'cloud-drive'
    $result | Should -Be 'stderr'
  }

  It 'returns all for service with no logging config' {
    $result = Get-CaptureMode -ServiceKey 'sshd'
    $result | Should -Be 'all'
  }
}

Describe 'Get-EventLogConfig' {
  It 'returns null for services without eventLog config' {
    $result = Get-EventLogConfig -ServiceKey 'ollama'
    $result | Should -BeNullOrEmpty
  }
}

Describe 'Test-ServiceHasLog' {
  BeforeEach {
    # Ensure Get-WinEvent returns nothing by default
    Mock Get-WinEvent { return @() }
  }

  It 'returns false for service with capture none' {
    Mock Get-CaptureMode { return 'none' } -ParameterFilter { $ServiceKey -eq 'sshd' }
    $result = Test-ServiceHasLog -ServiceKey 'sshd'
    $result | Should -Be $false
  }

  It 'returns false when no log files and no event log' {
    $result = Test-ServiceHasLog -ServiceKey 'ollama'
    $result | Should -Be $false
  }
}

Describe 'Show-ServiceList' {
  It 'outputs formatted lines without errors' {
    $output = Show-ServiceList
    $output | Should -Not -BeNullOrEmpty
    $output.Count | Should -Be 4
  }
}

Describe 'Show-LogConfig' {
  It 'outputs human-readable config' {
    $output = Show-LogConfig -ServiceKey 'ollama'
    $output | Should -Not -BeNullOrEmpty
    ($output -join "`n") | Should -Match 'ollama'
  }

  It 'outputs JSON with -JsonOut' {
    $output = Show-LogConfig -ServiceKey 'ollama' -JsonOut
    $output | Should -Not -BeNullOrEmpty
    $output | Should -Match '"ollama"'
  }
}

Describe 'Test-ServiceIsSystemScope' {
  It 'returns true for a system-scope entry' {
    $entry = @{ hostEntry = @{ scope = 'system' } }
    Test-ServiceIsSystemScope -ResolvedEntry $entry | Should -Be $true
  }

  It 'returns false for a user-scope entry' {
    $entry = @{ hostEntry = @{ scope = 'user' } }
    Test-ServiceIsSystemScope -ResolvedEntry $entry | Should -Be $false
  }

  It 'returns false when scope is absent' {
    $entry = @{ hostEntry = @{} }
    Test-ServiceIsSystemScope -ResolvedEntry $entry | Should -Be $false
  }
}
