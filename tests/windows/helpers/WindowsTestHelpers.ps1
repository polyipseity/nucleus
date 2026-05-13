# Shared helper functions for Windows Pester suites.
# Keep these helpers tiny and declarative so individual test files can stay
# focused on the managed state they validate.

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

    $pkg = winget list --exact -q $Id 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return @($pkg).Count -gt 0
}
