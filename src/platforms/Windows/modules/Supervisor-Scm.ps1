<#
.SYNOPSIS
    Supervisor backend for Windows SCM (Service Control Manager).
.DESCRIPTION
    Implements the uniform Supervisor-* interface used by the service watchdog.
    Native Windows services (Caddy, LiteLLM, Ollama, the OpenSSH pair, ...) are
    registered in SCM, so this adapter drives them with the Service cmdlets.

    Exactly one Supervisor-* adapter is loaded at a time. Both adapters expose
    the same eight functions with the same -Target signature, so the watchdog
    never branches on the service kind when it acts:

      Supervisor-Kind                     -> 'scm'
      Supervisor-Enabled  -Target         -> [bool]
      Supervisor-Live     -Target         -> [bool]
      Supervisor-Generation -Target         -> [int]
      Supervisor-LastExit -Target         -> [int]
      Supervisor-Start    -Target         -> no output
      Supervisor-Stop     -Target         -> no output
      Supervisor-Repair   -Target         -> no output

    -Target is the SCM service name.
.NOTES
    SCM exposes neither a restart counter nor a last exit code.  The generation
    token is therefore the service process id, which changes on every restart,
    and the exit probe reports zero.  Loop detection reads the restart history
    kept in the unified health record (ServiceHealth.ps1), which the watchdog
    owns — the same source the POSIX watchdog uses.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Supervisor-Kind — identifier of this adapter, used to load exactly one.
function Supervisor-Kind {
    <#
    .SYNOPSIS
      Returns this adapter's kind identifier.
    .OUTPUTS
      System.String
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'scm'
}

# Supervisor-Enabled — is the service registered and not explicitly disabled?
function Supervisor-Enabled {
    <#
    .SYNOPSIS
      Reports whether the service exists and is allowed to start.
    .DESCRIPTION
      A service the user set to Disabled is explicit intent, so it is reported
      as not enabled and the watchdog skips it instead of starting it.
    .PARAMETER Target
      SCM service name.
    .OUTPUTS
      System.Boolean
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

# Supervisor-Live — is the service currently running?
function Supervisor-Live {
    <#
    .SYNOPSIS
      Reports whether the service is running.
    .PARAMETER Target
      SCM service name.
    .OUTPUTS
      System.Boolean
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

# Get-ScmProcessId — process id of a registered service, or zero.
# WHY: the CIM cmdlets are Windows-only, so the process lookup is isolated here
# and every caller stays testable on a host where they cannot be resolved.
function Get-ScmProcessId {
    <#
    .SYNOPSIS
      Reports the process id backing a registered SCM service.
    .PARAMETER Target
      SCM service name.
    .OUTPUTS
      System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: an unregistered service is an expected state, not a failure
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Target'" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 0 }
    [int]$svc.ProcessId
}

# Supervisor-Generation — token that changes whenever the service starts a run.
function Supervisor-Generation {
    <#
    .SYNOPSIS
      Reports a token that changes whenever the service starts a new run.
    .DESCRIPTION
      SCM exposes no restart counter, so the token is the service process id:
      it changes on every (re)start and reads zero while the service is stopped.
      The watchdog compares successive tokens to spot restarts, which is why the
      value is only required to change, not to increase.
    .PARAMETER Target
      SCM service name.
    .OUTPUTS
      System.Int32
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return 0 }
    Get-ScmProcessId -Target $Target
}

# Supervisor-LastExit — last exit code for the service.
function Supervisor-LastExit {
    <#
    .SYNOPSIS
      Reports the service's last exit code.
    .DESCRIPTION
      SCM exposes no last exit code, so this always reports zero. The EX_CONFIG
      (78) repair rule is a launchd concept and has no SCM counterpart.
    .PARAMETER Target
      SCM service name.
    .OUTPUTS
      System.Int32
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return 0 }
    0
}

# Supervisor-Start — start the service.
function Supervisor-Start {
    <#
    .SYNOPSIS
      Starts the service.
    .PARAMETER Target
      SCM service name.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    Start-Service -Name $Target -ErrorAction Stop
}

# Supervisor-Stop — stop the service.
function Supervisor-Stop {
    <#
    .SYNOPSIS
      Stops the service.
    .PARAMETER Target
      SCM service name.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    # check-suppress:suppression_doc: a stop racing an already-stopped service is not a convergence failure
    Stop-Service -Name $Target -Force -ErrorAction SilentlyContinue
}

# Supervisor-Repair — stop then start the service.
function Supervisor-Repair {
    <#
    .SYNOPSIS
      Restarts the service so it picks up a clean supervisor state.
    .PARAMETER Target
      SCM service name.
    #>
    # check-suppress:SuppressMessageAttribute: PSUseApprovedVerbs -- Supervisor-* is the shared eight-function interface every adapter exposes
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    Supervisor-Stop -Target $Target
    Start-Sleep -Seconds 1
    Supervisor-Start -Target $Target
}
