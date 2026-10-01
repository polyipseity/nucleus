#!/usr/bin/env bash
# Install a PowerShell module at a pinned version for the current user, so the pin
# is the only copy PowerShell loads. Args: <pwsh-binary> <module-name>
# <module-version> [<privilege-command>], where the fourth is a resolved sudo path
# or empty and is needed only when a shadowing copy has to be removed.
#
# Called by scripts/bootstrap.sh and by the Pester, PSScriptAnalyzer, and
# powershell-yaml activation entries in src/modules/pwsh.nix.
set -euo pipefail

_ipm_pwsh="$1"
_ipm_module="$2"
_ipm_version="$3"
# WHY the default: the activation entries in src/modules/pwsh.nix pass no
#   privilege command, and a host with nothing to remove does not need one.
_ipm_privilege="${4:-}"

# WHY the skip: a host with no pwsh yet, or no pin to converge to, has nothing
#   to do here.
if [ ! -x "$_ipm_pwsh" ] || [ -z "$_ipm_version" ]; then
  exit 0
fi

# WHY one -Command for the whole program: the install and the verification have
#   to share one session to see each other's result, and the versions the
#   elevated child removes travel with it as arguments rather than through a
#   file.
# WHY the invocation is the last statement: under set -e the pwsh exit status
#   becomes this script's exit status, and the callers treat a non-zero status as
#   a failed step.
"$_ipm_pwsh" -NoProfile -Command "
  \$moduleName = '$_ipm_module'
  \$requiredVersion = [Version]'$_ipm_version'
  # WHY the binary is passed down rather than left to the elevated child's PATH:
  #   sudo runs a root environment, where a Nix-packaged pwsh is not resolvable.
  \$pwshBinary = '$_ipm_pwsh'
  \$privilegeCommand = '$_ipm_privilege'
  # WHY the removal program travels inside this one: it is handed the versions
  #   the listing below produced. It runs in its own process because a privileged
  #   copy cannot be removed from this one, and -ErrorAction Stop makes a refused
  #   removal abort rather than leave a shadow behind.
  \$removalProgram = @'
\$ErrorActionPreference = 'Stop'
# WHY the unload: a loaded copy holds its files open, which is what made
#   PowerShellGet refuse the removal and report the module as in use. The guard
#   keeps the unload off the path where nothing is loaded, so there is no error
#   to suppress.
\$moduleName = \$args[0]
if (Get-Module -Name \$moduleName) {
  Remove-Module -Name \$moduleName -Force
}
# WHY -RequiredVersion per copy and never -AllVersions: the converged pin lives
  #   at the same name, and only the version narrows the removal. A sweep would
  #   take the pin with them.
\$args | Select-Object -Skip 1 | ForEach-Object {
  Write-Host ('install-pwsh-module: elevated removal of ' + \$moduleName + ' ' + \$_) -ForegroundColor Yellow
  Uninstall-Module -Name \$moduleName -RequiredVersion \$_ -Force -ErrorAction Stop
}
'@
  # WHY the first entry of PSModulePath: PowerShellGet installs CurrentUser scope
  #   there, which leads the list on the hosts this script runs on. The Windows
  #   twin reads the last entry, because Windows PowerShell 5 appends it there.
  \$currentUserModulePath = @(\$env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { \$_ })[0]
  \$available = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY the converged copy is the pin under that path: Get-Module -ListAvailable
  #   returns one entry per version and per scope, and PowerShell breaks a tie
  #   between two copies of the same version by path order.
  \$converged = @(\$available | Where-Object { \$_.Version -eq \$requiredVersion -and \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY at or above the pin rather than merely different from it: PowerShell loads
  #   the highest version available, so a copy below the pin cannot shadow it.
  \$shadowing = @(\$available | Where-Object { \$_.Version -ge \$requiredVersion -and \$converged -notcontains \$_ })
  # WHY the early exit needs the two facts separately: nothing shadowing the pin
  #   is also true on a host holding only a lower copy and no pin, and reading
  #   that as converged skips the install the host is missing.
  if (\$converged.Count -gt 0 -and \$shadowing.Count -eq 0) {
    Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is already converged; no copy can shadow it') -ForegroundColor Green
    return
  }
  if (\$shadowing.Count -gt 0) {
    # WHY the guard and its throw share a line: the activation tool check reads
    #   these files line by line, and a line-leading throw reads to it as a bare
    #   external command. No other script under src/scripts carries one.
    if (-not \$privilegeCommand) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' cannot be converged: ' + ((@(\$shadowing | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase })) -join '; ') + ' can shadow the pin and no privilege command was supplied to remove them'; throw \$failure }
    Write-Host ('install-pwsh-module: removing ' + \$shadowing.Count + ' conflicting ' + \$moduleName + ' version(s) as ' + \$privilegeCommand + '...') -ForegroundColor Yellow
    \$shadowVersions = @(\$shadowing | ForEach-Object { '' + \$_.Version } | Select-Object -Unique)
    # WHY the call operator rather than a pipeline: the versions are arguments to
    #   the child, and a native command takes them the way it takes any argv.
    & \$privilegeCommand \$pwshBinary -NoProfile -CommandWithArgs \$removalProgram \$moduleName @(\$shadowVersions)
    if (\$LASTEXITCODE -ne 0) {
      # WHY the owner is read here: PowerShellGet reports \"in use or you don't
      #   have the required permissions\" for a copy this user cannot remove, and
      #   only the ownership of the copy says which half of that applies. The
      #   listing is in this session, so the paths are already known and no second
      #   elevated program is needed to read them.
      \$copies = @(\$shadowing | ForEach-Object {
        \$base = \$_.ModuleBase
        \$owner = 'unknown owner'
        if (Test-Path -LiteralPath \$base) {
          \$fields = @((& ls -ld \$base) -split '\s+' | Where-Object { \$_ -ne '' })
          if (\$fields.Count -gt 2) { \$owner = \$fields[2] }
        }
        \$_.Version.ToString() + ' at ' + \$base + ' (owner: ' + \$owner + ')'
      }) -join '; '
      \$failure = 'install-pwsh-module: could not remove ' + \$copies + ', which can shadow ' + \$moduleName + ' ' + \$requiredVersion + '; remove them with privilege the current user lacks, then re-run'; throw \$failure
    }
  }
  Write-Host ('install-pwsh-module: installing ' + \$moduleName + ' ' + \$requiredVersion + '...') -ForegroundColor Cyan
  Install-Module -Name \$moduleName -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  # WHY the fresh listing: Uninstall-Module -RequiredVersion works from the
  #   PSGallery package store, so a copy never installed from it (image-baked, or
  #   owned by another admin) survives the removal and keeps shadowing the pin.
  \$remaining = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY the pin is re-derived here: the listing after the install holds different
  #   objects, so the set membership has to come from it. A copy below the pin is
  #   left out of the failure for the same reason it is left out of the removal.
  \$remainingPin = @(\$remaining | Where-Object { \$_.Version -eq \$requiredVersion -and \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY the version floor on the leftover set: without it every copy that is not
  #   the converged pin fails the run, including a Pester 5.9.0 shipped beside a
  #   6.2.0 pin. A copy that cannot be loaded is not a leftover worth failing over.
  \$leftover = @(\$remaining | Where-Object { \$_.Version -ge \$requiredVersion -and \$remainingPin -notcontains \$_ })
  if (\$leftover.Count -gt 0) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed, but other copies remain: ' + ((\$leftover | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase }) -join '; '); throw \$failure }
  Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed and no copy can shadow it') -ForegroundColor Green
"
