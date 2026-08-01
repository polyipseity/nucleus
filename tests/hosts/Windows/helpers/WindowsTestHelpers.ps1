<#
.SYNOPSIS
    Shared helper functions for Windows Pester suites.
.DESCRIPTION
    Exports tiny, declarative helper functions so individual Pester test files
    can focus on the managed state they validate. Dot-source this file to
    import Get-NucleusRegistryValue, Get-NucleusUserEnvironmentVariable, and
    Test-NucleusWingetPackageInstalled.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure
#>

$ProgressPreference = 'SilentlyContinue'

function Get-NucleusRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        return Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-NucleusUserEnvironmentVariable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [System.Environment]::GetEnvironmentVariable($Name, 'User')
}

function Test-NucleusWingetPackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    # check-suppress:suppression_doc: probe -- package may not be installed; WHY: winget list returns empty output when package is absent; Should assertions handle null.
    $pkg = winget list --exact -q $Id 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return @($pkg).Count -gt 0
}
