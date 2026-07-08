<#
.SYNOPSIS
    Shared output formatting for nucleus-* PowerShell scripts.
.DESCRIPTION
    Provides Write-NucleusInfo, Write-NucleusError, Write-NucleusWarning,
    Write-NucleusDryRun, and Write-NucleusDone functions that format output
    consistently across all nucleus-* commands.

    These functions auto-derive the command name from the script path, so
    callers don't need to pass a prefix.

    Usage:
        Import-Module Format-NucleusOutput
        Write-NucleusInfo "processing 3 files"
        Write-NucleusError "file not found"
        Write-NucleusWarning "deprecated flag"
        Write-NucleusDryRun "would delete $path"
        Write-NucleusDone
#>

# Auto-derive the short command name from the script path.
# e.g., "scripts/gc.ps1" → "gc", "nucleus-gc" → "gc"
function Get-NucleusCommandName {
    $scriptPath = $PSCommandPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)
    if ($name -like 'nucleus-*') {
        $name = $name.Substring(8) # strip 'nucleus-'
    }
    return $name
}

function Write-NucleusInfo {
    <#
    .SYNOPSIS
        Print an info message to stdout.
    .PARAMETER Message
        The message text (without prefix).
    #>
    param([string]$Message)
    $cmd = Get-NucleusCommandName
    Write-Output "$cmd`: $Message"
}

function Write-NucleusError {
    <#
    .SYNOPSIS
        Print an error message to stderr.
    .PARAMETER Message
        The message text (without prefix).
    #>
    param([string]$Message)
    $cmd = Get-NucleusCommandName
    Write-Error "$cmd`: error: $Message"
}

function Write-NucleusWarning {
    <#
    .SYNOPSIS
        Print a warning message to stderr.
    .PARAMETER Message
        The message text (without prefix).
    #>
    param([string]$Message)
    $cmd = Get-NucleusCommandName
    Write-Warning "$cmd`: warning: $Message"
}

function Write-NucleusDryRun {
    <#
    .SYNOPSIS
        Print a dry-run message to stdout.
    .PARAMETER Message
        The action description (without prefix).
    #>
    param([string]$Message)
    $cmd = Get-NucleusCommandName
    Write-Output "$cmd`: [dry-run] $Message"
}

function Write-NucleusDone {
    <#
    .SYNOPSIS
        Print a completion message to stdout.
    #>
    $cmd = Get-NucleusCommandName
    Write-Output "$cmd`: done"
}

Export-ModuleMember -Function Write-NucleusInfo, Write-NucleusError, Write-NucleusWarning, Write-NucleusDryRun, Write-NucleusDone
