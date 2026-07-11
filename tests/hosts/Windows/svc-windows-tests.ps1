<#
.SYNOPSIS
  Pester tests for svc.ps1 internal functions.

.DESCRIPTION
  Tests the Format-StatusTable, Resolve-ServiceName, Get-ServiceStatus,
  and Invoke-ServiceAction functions by sourcing the function definitions
  from svc.ps1 with a mock $Registry.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/svc-windows-tests.ps1 -Passthru"
#>

BeforeAll {
  # Read svc.ps1 and extract function definitions using the PowerShell AST parser.
  # This handles nested braces correctly, unlike simple regex approaches.
  $svcPs1Path = Join-Path $PSScriptRoot '../../../scripts/svc.ps1'
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
      platform    = @{ type = 'native'; service = 'ollama' }
    }
    'sshd' = @{
      displayName = 'SSH Server'
      description = 'Remote shell access via SSH'
      network     = @{ default = @{ host = '0.0.0.0'; port = 22; protocol = 'tcp' } }
      platform    = @{ type = 'native'; service = 'sshd' }
    }
    'cloud-drive' = @{
      displayName = 'Cloud Drive Mounts'
      description = 'rclone FUSE cloud drive mounts'
      platform    = @{ type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'cloud-mount-' }
    }
    'camilladsp' = @{
      displayName = 'CamillaDSP'
      description = 'Audio processor'
      network     = @{ websocket = @{ host = '127.0.0.1'; port = 1234; protocol = 'tcp' } }
      platform    = @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
    }
  }

  # Script-scoped mock RegistryRaw (raw JSON structure before main processing).
  $Script:RegistryRaw = @{
    'ollama' = @{
      displayName = 'Ollama'
      description = 'LLM inference server'
      network     = @{ default = @{ host = '127.0.0.1'; port = 11434; protocol = 'http' } }
      platforms   = @{ windows = @{ type = 'native'; service = 'ollama'; logging = @{ capture = 'all' } } }
      logging     = @{ maxSize = 10000000 }
    }
    'sshd' = @{
      displayName = 'SSH Server'
      description = 'Remote shell access via SSH'
      network     = @{ default = @{ host = '0.0.0.0'; port = 22; protocol = 'tcp' } }
      platforms   = @{ windows = @{ type = 'native'; service = 'sshd' } }
    }
    'cloud-drive' = @{
      displayName = 'Cloud Drive Mounts'
      description = 'rclone FUSE cloud drive mounts'
      platforms   = @{ windows = @{ type = 'schtask'; taskPath = '\NucleusCloudMount'; prefixMatch = $true; service = 'cloud-mount-'; logging = @{ capture = 'stderr' } } }
    }
    'camilladsp' = @{
      displayName = 'CamillaDSP'
      description = 'Audio processor'
      network     = @{ websocket = @{ host = '127.0.0.1'; port = 1234; protocol = 'tcp' } }
      platforms   = @{ windows = @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' } }
    }
  }

  # Stubs are omitted — Pester Mock creates functions automatically when needed.

  # Mock external dependencies for log functions.
  Mock Get-NucleusLogDir { return 'TestDrive:\nucleus\logs' }
  Mock Get-NucleusSystemLogDir { return 'TestDrive:\nucleus\system-logs' }
  Mock Get-WinEvent { return @() }
  Mock ConvertTo-SanitizedText { process { $_ } }

  # Script-scoped platform (constant for Windows).
  $Script:Platform = 'windows'

  # Dot-source the function definitions.
  . ([scriptblock]::Create($functionCode))
}

# ---------------------------------------------------------------------------
# Format-StatusTable
# ---------------------------------------------------------------------------

Describe 'Format-StatusTable' {
  It 'outputs table with headers and separator when Json is false' {
    $Script:Json = $false
    $results = @{
      'ollama' = @{ status = 'active'; running = $true; pid = 12345 }
      'sshd'   = @{ status = 'inactive'; running = $false; pid = $null }
    }
    $output = Format-StatusTable -Results $results
    $output | Should -Not -BeNullOrEmpty
    $output | Should -Match 'ID\s+Name\s+Status\s+Running\s+PID'
    $output | Should -Match 'ollama'
    $output | Should -Match '12345'
    $output | Should -Match 'inactive'
  }

  It 'outputs compressed JSON when Json is true' {
    $Script:Json = $true
    $results = @{
      'ollama' = @{ status = 'active'; running = $true; pid = 12345 }
    }
    $output = Format-StatusTable -Results $results
    $output | Should -Not -BeNullOrEmpty
    $output | Should -Match '"version":"1"'
    $output | Should -Match '"services"'
    $output | Should -Match '"ollama"'
  }

  It 'skips ERROR: entries in JSON mode' {
    $Script:Json = $true
    $results = @{
      'ollama'  = @{ status = 'active'; running = $true; pid = 12345 }
      'ERROR:unknown' = @{ displayName = 'unknown'; platform = @{ error = 'service not found' } }
    }
    $output = Format-StatusTable -Results $results
    $output | Should -Not -Match 'ERROR'
  }

  It 'replaces ERROR: prefix with n/a in table mode' {
    $Script:Json = $false
    $results = @{
      'ERROR:unknown' = @{ displayName = 'unknown'; platform = @{ error = 'service not found' } }
    }
    $output = Format-StatusTable -Results $results
    $output | Should -Match 'unknown'
    $output | Should -Match 'n/a'
  }

  It 'formats PID as "-" when pid is null' {
    $Script:Json = $false
    $results = @{
      'sshd' = @{ status = 'inactive'; running = $false; pid = $null }
    }
    $output = Format-StatusTable -Results $results
    $lines = $output -split "`n"
    $dataLines = $lines | Where-Object { $_ -match 'sshd' }
    $dataLines | ForEach-Object { $_ | Should -Match '\s-\s*$' }
  }

  It 'formats PID as number when pid is present' {
    $Script:Json = $false
    $results = @{
      'ollama' = @{ status = 'active'; running = $true; pid = 9876 }
    }
    $output = Format-StatusTable -Results $results
    $lines = $output -split "`n"
    $dataLines = $lines | Where-Object { $_ -match 'ollama' }
    $dataLines | ForEach-Object { $_ | Should -Match '9876' }
  }
}

# ---------------------------------------------------------------------------
# Resolve-ServiceName
# ---------------------------------------------------------------------------

Describe 'Resolve-ServiceName' {
  It 'returns all non-prefix services when no names given' {
    $resolved = Resolve-ServiceName -Names @()
    $resolved.Keys | Should -Contain 'ollama'
    $resolved.Keys | Should -Contain 'sshd'
    $resolved.Keys | Should -Contain 'camilladsp'
  }

  It 'returns exact match for a known service' {
    $resolved = Resolve-ServiceName -Names @('ollama')
    $resolved.Keys | Should -Be @('ollama')
  }

  It 'returns ERROR: for unknown service' {
    $resolved = Resolve-ServiceName -Names @('nonexistent')
    $resolved.Keys | Should -Contain 'ERROR:nonexistent'
    $resolved['ERROR:nonexistent'].platform.error | Should -Be 'service not found in registry'
  }

  It 'resolves multiple services' {
    $resolved = Resolve-ServiceName -Names @('ollama', 'sshd')
    $resolved.Keys | Should -Contain 'ollama'
    $resolved.Keys | Should -Contain 'sshd'
  }

  It 'does not expand prefix-match services without names' {
    $resolved = Resolve-ServiceName -Names @()
    $resolved.Keys | Should -Not -Contain 'cloud-drive'
  }

  Context 'prefix expansion (schtask)' {
    It 'expands prefix-match with matching scheduled tasks' {
      Mock Get-ScheduledTask {
        return @(
          [PSCustomObject]@{ TaskName = 'cloud-mount-work'; TaskPath = '\NucleusCloudMount\'; State = 'Ready' }
        )
      }

      $resolved = Resolve-ServiceName -Names @('cloud-drive')
      $resolved.Keys | Should -Contain 'cloud-drive/cloud-mount-work'
      $resolved['cloud-drive/cloud-mount-work'].platform.type | Should -Be 'schtask'
    }

    It 'creates no-matches entry when no tasks match prefix' {
      Mock Get-ScheduledTask { return @() }

      $resolved = Resolve-ServiceName -Names @('cloud-drive')
      $resolved.Keys | Should -Contain 'cloud-drive/*'
      $resolved['cloud-drive/*'].displayName | Should -Be 'cloud-drive (no matches)'
    }
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

      $status = Get-ServiceStatus -Platform @{ type = 'native'; service = 'ollama' }
      $status.status | Should -Be 'active'
      $status.running | Should -Be $true
      $status.enabled | Should -Be $true
    }

    It 'returns inactive status for stopped service' {
      Mock Get-Service {
        return [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' }
      }

      $status = Get-ServiceStatus -Platform @{ type = 'native'; service = 'sshd' }
      $status.status | Should -Be 'inactive'
      $status.running | Should -Be $false
      $status.enabled | Should -Be $false
    }

    It 'returns not-found when Get-Service throws' {
      Mock Get-Service { throw 'not found' }

      $status = Get-ServiceStatus -Platform @{ type = 'native'; service = 'nonexistent' }
      $status.status | Should -Be 'not-found'
      $status.running | Should -Be $false
    }
  }

  Context 'schtask type' {
    It 'returns active for running task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Running' }
      }

      $status = Get-ServiceStatus -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'active'
      $status.running | Should -Be $true
    }

    It 'returns inactive for ready task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Ready' }
      }

      $status = Get-ServiceStatus -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'inactive'
      $status.running | Should -Be $false
      $status.enabled | Should -Be $true
    }

    It 'returns disabled for disabled task' {
      Mock Get-ScheduledTask {
        return [PSCustomObject]@{ State = 'Disabled' }
      }

      $status = Get-ServiceStatus -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $status.status | Should -Be 'disabled'
      $status.enabled | Should -Be $false
    }

    It 'returns not-found when Get-ScheduledTask throws' {
      Mock Get-ScheduledTask { throw 'not found' }

      $status = Get-ServiceStatus -Platform @{ type = 'schtask'; taskPath = '\Unknown' }
      $status.status | Should -Be 'not-found'
    }
  }

  Context 'unknown type' {
    It 'returns unknown status' {
      $status = Get-ServiceStatus -Platform @{ type = 'unsupported' }
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
      $Platform = $Script:Platform
      $Json = $Script:Json
      . ([scriptblock]::Create($dispatchSwitchText))
    }
  }

  BeforeEach {
    $Script:Json = $false
  }

  Context 'action routing' {
    It 'routes list to Resolve-ServiceName and Format-StatusTable' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345 } }
      Mock Format-StatusTable { return 'formatted' }

      Invoke-Dispatch -Action list

      Should -Invoke Resolve-ServiceName -Exactly 1
      Should -Invoke Format-StatusTable -Exactly 1
    }

    It 'routes status to Resolve-ServiceName and Format-StatusTable' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345 } }
      Mock Format-StatusTable { return 'formatted' }

      Invoke-Dispatch -Action status

      Should -Invoke Resolve-ServiceName -Exactly 1
      Should -Invoke Format-StatusTable -Exactly 1
    }

    It 'routes start to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action start -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'start' }
    }

    It 'routes stop to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action stop -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'stop' }
    }

    It 'routes restart to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action restart -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'restart' }
    }

    It 'routes enable to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Invoke-ServiceAction { return $true }

      Invoke-Dispatch -Action enable -ServiceName @('ollama')

      Should -Invoke Invoke-ServiceAction -Exactly 1 -ParameterFilter { $Action -eq 'enable' }
    }

    It 'routes disable to Invoke-ServiceAction' {
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
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
      Mock Get-PlatformService { return @('ollama') }
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
      { Invoke-Dispatch -Action endpoint } | Should -Throw 'svc: missing service name for endpoint'
    }

    It "start with no ServiceName throws" {
      { Invoke-Dispatch -Action start } | Should -Throw "svc: missing service name for 'start'"
    }

    It "stop with no ServiceName throws" {
      { Invoke-Dispatch -Action stop } | Should -Throw "svc: missing service name for 'stop'"
    }

    It "restart with no ServiceName throws" {
      { Invoke-Dispatch -Action restart } | Should -Throw "svc: missing service name for 'restart'"
    }

    It "enable with no ServiceName throws" {
      { Invoke-Dispatch -Action enable } | Should -Throw "svc: missing service name for 'enable'"
    }

    It "disable with no ServiceName throws" {
      { Invoke-Dispatch -Action disable } | Should -Throw "svc: missing service name for 'disable'"
    }

    It 'logs with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action logs -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc logs: unknown service*'
    }

    It 'log-paths with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action log-paths -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc log-paths: unknown service*'
    }

    It 'log-config with unknown service writes error' {
      Mock Write-Error { throw "Write-Error: $Message" }

      { Invoke-Dispatch -Action log-config -ServiceName @('nonexistent') } | Should -Throw 'Write-Error: svc log-config: unknown service*'
    }
  }

  Context 'JSON routing' {
    It 'list with Json outputs JSON through Format-StatusTable' {
      $Script:Json = $true
      Mock Resolve-ServiceName { return @{ 'ollama' = $Script:Registry['ollama'] } }
      Mock Get-ServiceStatus { return @{ status = 'active'; running = $true; pid = 12345; displayName = 'Ollama' } }

      $output = Invoke-Dispatch -Action list

      $output | Should -Match '"version":"1"'
    }

    It 'log-config with Json passes -JsonOut to Show-LogConfig' {
      $Script:Json = $true
      Mock Show-LogConfig { }

      Invoke-Dispatch -Action log-config -ServiceName @('ollama')

      Should -Invoke Show-LogConfig -Exactly 1 -ParameterFilter { $ServiceKey -eq 'ollama' -and $JsonOut }
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

      $result = Invoke-ServiceAction -Action 'start' -Platform @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Start-Service -Exactly 1
    }

    It 'stops a service and returns $true' {
      Mock Stop-Service { }

      $result = Invoke-ServiceAction -Action 'stop' -Platform @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Stop-Service -Exactly 1
    }

    It 'restarts a service and returns $true' {
      Mock Restart-Service { }

      $result = Invoke-ServiceAction -Action 'restart' -Platform @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Restart-Service -Exactly 1
    }

    It 'enables a service and returns $true' {
      Mock Set-Service { }

      $result = Invoke-ServiceAction -Action 'enable' -Platform @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Set-Service -Exactly 1 -ParameterFilter { $StartupType -eq 'Automatic' }
    }

    It 'disables a service and returns $true' {
      Mock Set-Service { }

      $result = Invoke-ServiceAction -Action 'disable' -Platform @{ type = 'native'; service = 'ollama' }
      $result | Should -Be $true
      Should -Invoke Set-Service -Exactly 1 -ParameterFilter { $StartupType -eq 'Disabled' }
    }

    It 'returns status via Get-ServiceStatus' {
      Mock Get-Service {
        return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
      }

      $result = Invoke-ServiceAction -Action 'status' -Platform @{ type = 'native'; service = 'ollama' }
      $result.status | Should -Be 'active'
    }
  }

  Context 'schtask type' {
    It 'starts a scheduled task and returns $true' {
      Mock Start-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'start' -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Start-ScheduledTask -Exactly 1
    }

    It 'stops a scheduled task and returns $true' {
      Mock Stop-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'stop' -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Stop-ScheduledTask -Exactly 1
    }

    It 'restarts a scheduled task (stop then start) and returns $true' {
      Mock Stop-ScheduledTask { }
      Mock Start-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'restart' -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Stop-ScheduledTask -Exactly 1
      Should -Invoke Start-ScheduledTask -Exactly 1
    }

    It 'enables a scheduled task and returns $true' {
      Mock Enable-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'enable' -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Enable-ScheduledTask -Exactly 1
    }

    It 'disables a scheduled task and returns $true' {
      Mock Disable-ScheduledTask { }

      $result = Invoke-ServiceAction -Action 'disable' -Platform @{ type = 'schtask'; taskPath = '\NucleusCamillaDSP' }
      $result | Should -Be $true
      Should -Invoke Disable-ScheduledTask -Exactly 1
    }
  }

  Context 'unsupported type' {
    It 'throws for unsupported type' {
      { Invoke-ServiceAction -Action 'start' -Platform @{ type = 'unknown' } } | Should -Throw
    }
  }
}

# ---------------------------------------------------------------------------
# Log helper functions
# ---------------------------------------------------------------------------

Describe 'Get-PlatformService' {
  It 'returns sorted service names' {
    $result = Get-PlatformService
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
