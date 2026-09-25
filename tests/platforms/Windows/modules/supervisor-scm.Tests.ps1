<#
.SYNOPSIS
  Pester tests for the SCM supervisor adapter.

.DESCRIPTION
  The watchdog loads exactly one Supervisor-* adapter per service kind, so the
  adapter must expose the uniform interface and translate -Target into the
  native SCM cmdlets.  Get-Service, Start-Service, and Stop-Service are stubbed
  on hosts where they do not exist so the suite runs anywhere.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/supervisor-scm.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $modulesDir = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules'
  . (Join-Path $modulesDir 'Supervisor-Scm.ps1')

  $stubs = @{
    'Get-Service'   = 'param([string]$Name)'
    'Start-Service' = 'param([string]$Name)'
    'Stop-Service'  = 'param([string]$Name, [switch]$Force)'
  }
  foreach ($name in $stubs.Keys) {
    if (-not (Get-Command -Name $name -ErrorAction Ignore)) {
      Set-Item -Path "Function:$name" -Value ([scriptblock]::Create("$($stubs[$name])`nthrow 'stub: override with Mock'"))
    }
  }
}

Describe 'Supervisor-Kind' {
  It 'identifies the adapter' {
    (Supervisor-Kind) | Should -Be 'scm'
  }
}

Describe 'Supervisor-Enabled' {
  It 'is false when the service is not registered' {
    Mock Get-Service { return $null }

    (Supervisor-Enabled -Target 'ghost') | Should -BeFalse
  }

  It 'is false when the user disabled the service' {
    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Stopped'; StartType = 'Disabled' } }

    (Supervisor-Enabled -Target 'ollama') | Should -BeFalse
  }

  It 'is true for an enabled service' {
    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Stopped'; StartType = 'Automatic' } }

    (Supervisor-Enabled -Target 'ollama') | Should -BeTrue
  }
}

Describe 'Supervisor-Live' {
  It 'is true only while the service runs' {
    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Running'; StartType = 'Automatic' } }
    (Supervisor-Live -Target 'ollama') | Should -BeTrue

    Mock Get-Service { return [PSCustomObject]@{ Name = 'ollama'; Status = 'Stopped'; StartType = 'Automatic' } }
    (Supervisor-Live -Target 'ollama') | Should -BeFalse
  }

  It 'is false when the service is not registered' {
    Mock Get-Service { return $null }

    (Supervisor-Live -Target 'ghost') | Should -BeFalse
  }
}

Describe 'Supervisor-Generation and Supervisor-LastExit' {
  It 'reports the service process id as the generation token' {
    Mock Get-ScmProcessId { return 4242 }

    (Supervisor-Generation -Target 'ollama') | Should -Be 4242
    (Supervisor-LastExit -Target 'ollama') | Should -Be 0
  }

  It 'reports zero when the service has no process' {
    Mock Get-ScmProcessId { return 0 }

    (Supervisor-Generation -Target 'ghost') | Should -Be 0
  }
}

Describe 'Supervisor-Start' {
  It 'starts the service named by -Target' {
    $script:Started = @()
    Mock Start-Service { $script:Started += $Name }

    Supervisor-Start -Target 'nucleus-caddy'

    $script:Started | Should -Be @('nucleus-caddy')
  }
}

Describe 'Supervisor-Stop' {
  It 'stops the service named by -Target' {
    $script:Stopped = @()
    Mock Stop-Service { $script:Stopped += $Name }

    Supervisor-Stop -Target 'nucleus-caddy'

    $script:Stopped | Should -Be @('nucleus-caddy')
  }
}

Describe 'Supervisor-Repair' {
  It 'stops and then starts the service' {
    $script:Calls = @()
    Mock Stop-Service { $script:Calls += "stop:$Name" }
    Mock Start-Service { $script:Calls += "start:$Name" }
    Mock Start-Sleep { }

    Supervisor-Repair -Target 'nucleus-caddy'

    $script:Calls | Should -Be @('stop:nucleus-caddy', 'start:nucleus-caddy')
  }
}
