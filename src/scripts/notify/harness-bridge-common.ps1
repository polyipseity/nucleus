<#
.SYNOPSIS
  Shared helpers for the Windows harness-bridge entry points.

.DESCRIPTION
  harness-notify.ps1, harness-approval.ps1, and harness-drive.ps1 each dot-source
  this file, so the warning line, the nucleus root, and the runtime config path
  have one definition.

  The entry points are deployed verbatim to <USER root>\bin and reached from
  harness hooks through the %USERPROFILE%\.local\bin\*.cmd shims, and this file
  is copied beside them by Sync-HarnessBridge.  That is also why nothing here
  imports Format-NucleusOutput.psm1: a repository path would not exist in the
  deployed copy.  This file is never invoked as a command, so it gets no shim.

  Warning output keeps the F1 shape (`<cmd>: warning: <msg>`) on stderr minus
  console color, which a hook never sees anyway.
#>

function Write-HarnessBridgeWarning {
  <#
  .SYNOPSIS
    Writes one F1 warning line to stderr without importing the shared module.
  .DESCRIPTION
    See the file header: this helper is deployed outside the repository, so it
    cannot import Format-NucleusOutput.psm1.  The line keeps the F1 shape minus
    console color, which a hook never sees anyway.
  .PARAMETER CommandName
    F1 command prefix.
  .PARAMETER Message
    Warning text.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$CommandName,

    [Parameter(Mandatory)]
    [string]$Message
  )

  [Console]::Error.WriteLine("${CommandName}: warning: $Message")
}

function Get-HarnessBridgeUserRoot {
  <#
  .SYNOPSIS
    Resolves the Windows nucleus USER root.
  .DESCRIPTION
    Mirrors Get-NucleusUserRoot in ManagedPaths.ps1, inlined because the entry
    points are deployed outside the repository.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw '%LOCALAPPDATA% is unset; the nucleus USER root is undefined'
  }
  return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus')
}

function Get-HarnessBridgeConfigPath {
  <#
  .SYNOPSIS
    Resolves the nucleus runtime config path.
  .DESCRIPTION
    Same location `scripts/config.ps1` (nucleus-config) reads and writes.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  return (Join-Path -Path $HOME -ChildPath '.local/state/nucleus/config.json')
}
