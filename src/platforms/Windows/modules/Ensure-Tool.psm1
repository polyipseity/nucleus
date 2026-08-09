<#
.SYNOPSIS
    Tool availability validation for check/test pre-flight blocks.
.DESCRIPTION
    Provides Assert-ToolAvailable function that checks whether a required tool
    (command or PowerShell module) is available, and errors with an
    install hint if missing.

    This is the Windows counterpart to require_command/ensure_tool in
    src/scripts/lib.sh.

    POLICY: This module MUST NOT accept an InstallCommand parameter — preflight
    checks must fail hard on missing tools, not suggest ad-hoc installation.
    Provisioning and preflight are separate: bootstrap/apply installs tools;
    preflight only verifies presence (see tooling-and-validation.instructions.md).
    Tools must be provisioned via bootstrap or nucleus-apply, not per-check
    install commands.

    Usage:
        Import-Module Ensure-Tool (note: module filename differs from exported function name)
        Assert-ToolAvailable -Name 'powershell-yaml' -Type 'Module'
        Assert-ToolAvailable -Name 'packer' -Type 'Command'
#>

function Assert-ToolAvailable {
    <#
    .SYNOPSIS
        Verify a required tool is available; exit with a message if not.
    .PARAMETER Name
        Tool name (command name or PowerShell module name).
    .PARAMETER Type
        'Command' (default) for PATH executables, 'Module' for PowerShell modules.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Command', 'Module')]
        [string]$Type = 'Command'
    )

    $available = $false
    if ($Type -eq 'Command') {
        $available = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    } elseif ($Type -eq 'Module') {
        $available = [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
    }

    if (-not $available) {
        $message = "check: error: $Name is required but was not found. Run bootstrap or nucleus-apply to install it."
        Write-Output $message
        exit 1
    }
}

Export-ModuleMember -Function Assert-ToolAvailable
