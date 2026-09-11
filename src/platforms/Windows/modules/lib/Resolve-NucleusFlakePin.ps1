# Resolve-NucleusFlakePin.ps1 — resolve a flake.lock node into an install source.
#
# A tool declared with "pin": "flake:<node>" in src/modules/packages/desired.json
# must match the revision the declarative POSIX provisioning uses, which no
# published release tracks.  This helper turns the node into the repository URL
# and revision both callers need, so the parsing lives in exactly one place.
#
# Consumers:
#   - src/platforms/Windows/modules/setup/Invoke-UvSetup.ps1 (install source)
#   - src/scripts/checks/lockfile-enforcement-lib.ps1 (expected revision)

<#
.SYNOPSIS
    Resolves a flake.lock node into a GitHub source and revision.
.DESCRIPTION
    Reads the locked input for a flake node and returns either a usable pin or a
    reason code.  Failures are returned rather than thrown so each caller can
    report them in its own voice (install-time hard error, or a drift report).
.PARAMETER Node
    flake.lock node name, for example 'hermes-agent'.
.PARAMETER FlakeLockPath
    Path to the repository's flake.lock.
.OUTPUTS
    Hashtable.  On success: @{ Ok = $true; Source = 'https://github.com/<owner>/<repo>'; Rev = '<rev>' }.
    On failure: @{ Ok = $false; Reason = '<missing-lockfile|missing-node|not-github>'; Node = '<node>' }.
.EXAMPLE
    Resolve-NucleusFlakePin -Node 'hermes-agent' -FlakeLockPath 'src\flake.lock'
#>
function Resolve-NucleusFlakePin {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Node,
    [Parameter(Mandatory = $true)]
    [string]$FlakeLockPath
  )

  if (-not (Test-Path -LiteralPath $FlakeLockPath)) {
    return @{ Ok = $false; Reason = 'missing-lockfile'; Node = $Node }
  }

  $lock = Get-Content -LiteralPath $FlakeLockPath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $lock.ContainsKey('nodes') -or -not $lock.nodes.ContainsKey($Node)) {
    return @{ Ok = $false; Reason = 'missing-node'; Node = $Node }
  }

  $locked = $lock.nodes[$Node].locked
  if ($null -eq $locked -or -not $locked.rev -or $locked.type -ne 'github' -or -not $locked.owner -or -not $locked.repo) {
    return @{ Ok = $false; Reason = 'not-github'; Node = $Node }
  }

  return @{
    Ok     = $true
    Source = "https://github.com/$($locked.owner)/$($locked.repo)"
    Rev    = $locked.rev
  }
}
