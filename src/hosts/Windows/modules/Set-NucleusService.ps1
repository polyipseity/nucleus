# Dot-source this file from any Sync-* function that manages Windows services.
# These functions implement the standard SCM lifecycle pattern used by nucleus
# managed services: create-or-update with stop/start orchestration.
#
# Usage:
#   . (Join-Path -Path $PSScriptRoot -ChildPath "..\Set-NucleusService.ps1")

function Set-NucleusService {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$BinaryPath,
    [Parameter(Mandatory)]
    [string]$DisplayName,
    [string]$Description,
    [ValidateSet('Automatic', 'Manual', 'Disabled')]
    [string]$StartType = 'Automatic'
  )

  # undoc-supp: probe whether the service already exists; Get-Service throws when absent.
  $existingService = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($null -eq $existingService) {
    if ($PSCmdlet.ShouldProcess($Name, 'Create service')) {
      & sc.exe create $Name binPath= $BinaryPath start= $StartType DisplayName= $DisplayName | Out-Null
      if ($Description) {
        & sc.exe description $Name $Description | Out-Null
      }
    }
  }
  else {
    if ($PSCmdlet.ShouldProcess($Name, 'Update service')) {
      if ($existingService.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force
      }
      & sc.exe config $Name binPath= $BinaryPath start= $StartType | Out-Null
    }
  }

  if ($PSCmdlet.ShouldProcess($Name, 'Start service')) {
    Start-Service -Name $Name
  }
}

function Remove-NucleusService {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  # undoc-supp: probe whether the service exists; Get-Service throws when absent.
  $existingService = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($null -ne $existingService) {
    if ($PSCmdlet.ShouldProcess($Name, 'Remove service')) {
      if ($existingService.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force
      }
      & sc.exe delete $Name | Out-Null
    }
  }
}
