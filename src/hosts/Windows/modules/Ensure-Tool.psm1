<#
.SYNOPSIS
    Tool availability validation for check.ps1 pre-flight block.
.DESCRIPTION
    Provides Assert-ToolAvailable function that checks whether a required tool
    (command or PowerShell module) is available, and errors with an
    install hint if missing.

    This is the Windows counterpart to require_command/ensure_tool in
    src/scripts/lib.sh — but with provisioning hints (winget, Install-Module)
    instead of just erroring, since Windows lacks a unified package manager
    like nixpkgs in the nucleus-apply path.

    Usage:
        Import-Module Ensure-Tool (note: module filename differs from exported function name)
        Assert-ToolAvailable -Name 'powershell-yaml' -Type 'Module'
        Assert-ToolAvailable -Name 'packer' -Type 'Command' -InstallCommand 'winget install Hashicorp.Packer'
#>

function Assert-ToolAvailable {
    <#
    .SYNOPSIS
        Verify a required tool is available; exit with a message if not.
    .PARAMETER Name
        Tool name (command name or PowerShell module name).
    .PARAMETER Type
        'Command' (default) for PATH executables, 'Module' for PowerShell modules.
    .PARAMETER InstallCommand
        Optional command to suggest for installation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Command', 'Module')]
        [string]$Type = 'Command',

        [Parameter(Mandatory = $false)]
        [string]$InstallCommand = ''
    )

    $available = $false
    if ($Type -eq 'Command') {
        $available = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    } elseif ($Type -eq 'Module') {
        $available = [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
    }

    if (-not $available) {
        $message = "check: error: $Name is required but was not found"
        if ($InstallCommand) {
            $message += ". Install with: $InstallCommand"
        } else {
            $message += ". Run bootstrap or nucleus-apply to install it."
        }
        Write-Output $message
        exit 1
    }
}

Export-ModuleMember -Function Assert-ToolAvailable
