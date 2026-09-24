<#
.SYNOPSIS
    Supervisor backend for Windows SCM (Service Control Manager).
.DESCRIPTION
    Implements Supervisor-* functions for the service-watchdog core runner.
    Handles native Windows services (Caddy, LiteLLM, Ollama, etc).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Supervisor-Enabled — is the service configured to start?
function Supervisor-Enabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $null -ne $svc
}

# Supervisor-Live — is the service running?
function Supervisor-Live {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $svc -and $svc.Status -eq 'Running'
}

# Supervisor-Counter — return the number of times the service has restarted.
# SCM does not expose NRestarts directly; return 0 (loop detection relies
# on the watchdog's own bookkeeping for SCM services).
function Supervisor-Counter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    0
}

# Supervisor-LastExit — SCM does not expose last exit code; return 0.
function Supervisor-LastExit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    0
}

# Supervisor-Start — start a Windows service.
function Supervisor-Start {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    Start-Service -Name $ServiceName -ErrorAction Stop
}

# Supervisor-Stop — stop a Windows service.
function Supervisor-Stop {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
}

# Supervisor-Repair — stop + start a service.
function Supervisor-Repair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    Supervisor-Stop -ServiceName $ServiceName
    Start-Sleep -Seconds 1
    Supervisor-Start -ServiceName $ServiceName
}

# Supervisor-Kind — return the supervisor kind identifier.
function Supervisor-Kind {
    'scm'
}
