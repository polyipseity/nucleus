#!/usr/bin/env bash
# Install a PowerShell module at a pinned version for the current user, so the
# pin ends up as the only copy of that module PowerShell will load.
#
# CLI args: <pwsh-binary> <module-name> <module-version>
#
# A copy below the pin is left alone: PowerShell loads the highest version
# available, so such a copy is inert and cannot shadow the pin. Every copy at or
# above the pin is a target, including a copy of the pin itself at a scope this
# script does not own, because a tie on version is broken by path order.
#
# Exit conditions:
#   0  the pin is in place under the per-user module path with nothing shadowing
#      it, or there is nothing to converge: the pwsh binary is not executable, or
#      the version argument is empty
#   non-zero  pwsh reported a failure, or the post-install check found a copy
#      that could shadow the pin, naming that copy's version and path
#
# Called by scripts/bootstrap.sh and by the three module activation entries in
# src/modules/pwsh.nix (Pester, PSScriptAnalyzer, powershell-yaml).
set -euo pipefail

_ipm_pwsh="$1"
_ipm_module="$2"
_ipm_version="$3"

# WHY the skip: a host with no pwsh yet, or no pin to converge to, has nothing to
# do here, so this is a no-op rather than a failure. bootstrap.sh calls this
# before PowerShell exists on a fresh host.
if [ ! -x "$_ipm_pwsh" ] || [ -z "$_ipm_version" ]; then
  exit 0
fi

# WHY one -Command for the whole program: PowerShellGet decides a module is "in
#   use" from the state of the session doing the removal, so the unload, the
#   removal, the install and the verification have to share one session to see
#   each other's result.
# WHY the invocation is the last statement: under set -e the pwsh exit status
#   becomes this script's exit status, and the callers treat a non-zero status as
#   a failed step. An Uninstall-Module that stops on error, and a verification
#   that throws, have to abort the caller instead of printing a red line.
"$_ipm_pwsh" -NoProfile -Command "
  \$moduleName = '$_ipm_module'
  \$requiredVersion = [Version]'$_ipm_version'
  # WHY the first entry of PSModulePath: PowerShellGet installs CurrentUser scope
  #   into the per-user module path, which leads the list on the hosts this script
  #   runs on. The Windows twin reads the last entry instead, because Windows
  #   PowerShell 5 appends the per-user path there.
  \$currentUserModulePath = @(\$env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { \$_ })[0]
  \$available = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY the converged copy is the pin under that path: Get-Module -ListAvailable
  #   returns one entry per version and per scope, and PowerShell breaks a tie
  #   between two copies of the same version by path order, so a copy of the pin
  #   at a scope this script does not own outranks the per-user one.
  \$converged = @(\$available | Where-Object { \$_.Version -eq \$requiredVersion -and \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY at or above the pin rather than merely different from it: PowerShell
  #   loads the highest version available, so a copy below the pin is inert and
  #   cannot shadow it. That is the Pester 5.9.0 the CI runner image ships beside
  #   a 6.2.0 pin, and sweeping it is what turned that runner red.
  \$shadowing = @(\$available | Where-Object { \$_.Version -ge \$requiredVersion -and \$converged -notcontains \$_ })
  # WHY the early exit needs the two facts separately: nothing shadowing the pin
  #   is also true on a host holding only a lower copy and no pin at all, and
  #   reading that as converged skips the install the host is actually missing.
  if (\$converged.Count -gt 0 -and \$shadowing.Count -eq 0) {
    Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is already converged; no copy can shadow it') -ForegroundColor Green
    return
  }
  if (\$shadowing.Count -gt 0) {
    # WHY unload first: a loaded copy holds its files open, which is what made
    #   PowerShellGet refuse the removal and report the module as in use. The
    #   guard keeps the unload off the path where nothing is loaded, so there is
    #   no error here to suppress.
    if (Get-Module -Name \$moduleName) {
      Remove-Module -Name \$moduleName -Force
    }
    Write-Host ('install-pwsh-module: removing ' + \$shadowing.Count + ' conflicting ' + \$moduleName + ' version(s)...') -ForegroundColor Yellow
    # WHY -ErrorAction Stop: without it a refused removal is a red line, the
    #   install below still runs, and the pin lands next to the copy that
    #   shadows it.
    Uninstall-Module -Name \$moduleName -AllVersions -Force -ErrorAction Stop
  }
  Write-Host ('install-pwsh-module: installing ' + \$moduleName + ' ' + \$requiredVersion + '...') -ForegroundColor Cyan
  Install-Module -Name \$moduleName -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  # WHY the fresh listing: Uninstall-Module -AllVersions works from the PSGallery
  #   package store, so a copy that was never installed from it (an image-baked
  #   copy, or one another admin owns) survives the removal and keeps shadowing
  #   the pin. Only a listing taken after the install can catch that.
  \$remaining = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY the pin is re-derived here instead of reusing \$converged: the listing
  #   after the install is a different set of objects from the one before it, so
  #   the set membership that carves out the converged copy has to be taken from
  #   this listing. A copy below the pin is left out of the failure for the same
  #   reason it is left out of the sweep: it cannot be what gets loaded.
  \$remainingPin = @(\$remaining | Where-Object { \$_.Version -eq \$requiredVersion -and \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY the version floor on the leftover set: without it every copy that is not
  #   the converged pin fails the run, including one below the pin, and the
  #   Pester 5.9.0 the CI runner image ships beside a 6.2.0 pin turns the step
  #   red on a host that is already correct. A copy that cannot be loaded is not
  #   a leftover worth failing over.
  \$leftover = @(\$remaining | Where-Object { \$_.Version -ge \$requiredVersion -and \$remainingPin -notcontains \$_ })
  # WHY the guard and its throw share a line: the activation tool check reads
  #   these files line by line, and a line-leading throw reads to it as a bare
  #   external command. No other script under src/scripts carries one.
  if (\$leftover.Count -gt 0) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed, but other copies remain: ' + ((\$leftover | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase }) -join '; '); throw \$failure }
  Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed and no copy can shadow it') -ForegroundColor Green
"
