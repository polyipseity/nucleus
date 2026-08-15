# Dot-source this file from any Sync-* function that creates protected symlinks.
# These functions add a Windows ACL that denies the current user the "delete"
# permission on the symlink itself (/L), so the link cannot be removed accidentally.

function Set-ManagedSymlinkDeleteProtection {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Context,
    [Parameter(Mandatory)]
    [string]$Path
  )

  $principal = "$env:USERDOMAIN\$env:USERNAME"
  if ($PSCmdlet.ShouldProcess($Path, "Apply symlink delete-protection ACL")) {
    $grantResult = (& icacls $Path /L /deny "${principal}:(D)" 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusWarning -CommandName $Context "could not apply delete-protection ACL to ${Path} : $grantResult"
    }
  }
}

function Remove-ManagedSymlinkDeleteProtection {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Context,
    [Parameter(Mandatory)]
    [string]$Path
  )

  $principal = "$env:USERDOMAIN\$env:USERNAME"
  if ($PSCmdlet.ShouldProcess($Path, "Remove symlink delete-protection ACL")) {
    $removeResult = (& icacls $Path /L /remove:d $principal 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusWarning -CommandName $Context "could not clear delete-protection ACL from ${Path} before update : $removeResult"
    }
  }
}
