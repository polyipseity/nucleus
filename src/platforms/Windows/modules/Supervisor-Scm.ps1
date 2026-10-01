<#
.SYNOPSIS
    Supervisor backend for Windows SCM (Service Control Manager).
.DESCRIPTION
    One of the Supervisor-* adapters the service watchdog loads. Native Windows
    services (Caddy, LiteLLM, Ollama, the OpenSSH pair) are registered in SCM, so
    this one drives them with the Service cmdlets. -Target is the SCM service name.
.NOTES
    SCM exposes neither a restart counter nor a last exit code. The generation
    token is the service process id, which changes on every restart, and the exit
    probe reports zero. Loop detection reads the restart history in the unified
    health record (ServiceHealth.ps1).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Supervisor-Kind {
    <#
    .SYNOPSIS
      Returns this adapter's kind identifier.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'scm'
}

function Supervisor-Enabled {
    <#
    .SYNOPSIS
      Reports whether the service exists and is allowed to start.
    .DESCRIPTION
      A service the user set to Disabled is explicit intent, so it reports as not
      enabled and the watchdog skips it.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: an unregistered service is an expected state, not a failure
    $svc = Get-Service -Name $Target -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $false }
    $svc.StartType -ne 'Disabled'
}

function Supervisor-Live {
    <#
    .SYNOPSIS
      Reports whether the service is running.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: an unregistered service is an expected state, not a failure
    $svc = Get-Service -Name $Target -ErrorAction SilentlyContinue
    $null -ne $svc -and $svc.Status -eq 'Running'
}

# WHY: the CIM cmdlets are Windows-only, so the process lookup is isolated here
# and every caller stays testable on a host where they cannot be resolved.
function Get-ScmProcessId {
    <#
    .SYNOPSIS
      Reports the process id backing a registered SCM service.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: an unregistered service is an expected state, not a failure
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Target'" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 0 }
    [int]$svc.ProcessId
}

function Supervisor-Generation {
    <#
    .SYNOPSIS
      Reports a token that changes whenever the service starts a new run.
    .DESCRIPTION
      SCM exposes no restart counter, so the token is the service process id. The
      watchdog only needs it to change, not to increase.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return 0 }
    Get-ScmProcessId -Target $Target
}

function Supervisor-LastExit {
    <#
    .SYNOPSIS
      Reports the service's last exit code.
    .DESCRIPTION
      Always zero: SCM exposes no exit code, and the EX_CONFIG (78) repair rule is
      a launchd concept with no SCM counterpart.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return 0 }
    0
}

function Supervisor-Start {
    <#
    .SYNOPSIS
      Starts the service.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    Start-Service -Name $Target -ErrorAction Stop
}

function Supervisor-Stop {
    <#
    .SYNOPSIS
      Stops the service.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: a stop racing an already-stopped service is not a convergence failure
    Stop-Service -Name $Target -Force -ErrorAction SilentlyContinue
}

function Supervisor-Repair {
    <#
    .SYNOPSIS
      Restarts the service so it picks up a clean supervisor state.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    Supervisor-Stop -Target $Target
    Start-Sleep -Seconds 1
    Supervisor-Start -Target $Target
}
