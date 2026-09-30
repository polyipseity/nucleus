#!/usr/bin/env bash
# Install a PowerShell module at a pinned version for the current user, so the
# pin ends up as the only copy of that module the user can load.
#
# CLI args: <pwsh-binary> <module-name> <module-version>
#
# Exit conditions:
#   0  the pin is installed and is the only version Get-Module -ListAvailable
#      reports, or there is nothing to converge: the pwsh binary is not
#      executable, or the version argument is empty
#   non-zero  pwsh reported a failure, or the post-install check found a copy
#      beside the pin, naming that copy's version and path
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
  \$available = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY every copy and not the first: Get-Module -ListAvailable returns one entry
  #   per version and per scope, so a host carrying 5.9.0 beside 6.2.0 keeps the
  #   stale copy in the module path, where it is the one that gets loaded.
  \$stale = @(\$available | Where-Object { \$_.Version -ne \$requiredVersion })
  # WHY the early exit is the absence of a stale copy rather than the presence of
  #   the pin: a host that already has the pin beside a stale copy is the case
  #   this script exists to fix, and reading it as converged is what left both
  #   copies behind.
  if (\$available.Count -gt 0 -and \$stale.Count -eq 0) {
    Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is already the only copy') -ForegroundColor Green
    return
  }
  if (\$stale.Count -gt 0) {
    # WHY unload first: a loaded copy holds its files open, which is what made
    #   PowerShellGet refuse the removal and report the module as in use. The
    #   guard keeps the unload off the path where nothing is loaded, so there is
    #   no error here to suppress.
    if (Get-Module -Name \$moduleName) {
      Remove-Module -Name \$moduleName -Force
    }
    Write-Host ('install-pwsh-module: removing ' + \$stale.Count + ' stale ' + \$moduleName + ' version(s)...') -ForegroundColor Yellow
    # WHY -ErrorAction Stop: without it a refused removal is a red line, the
    #   install below still runs, and the pin lands next to the stale copy.
    Uninstall-Module -Name \$moduleName -AllVersions -Force -ErrorAction Stop
  }
  Write-Host ('install-pwsh-module: installing ' + \$moduleName + ' ' + \$requiredVersion + '...') -ForegroundColor Cyan
  Install-Module -Name \$moduleName -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  # WHY the fresh listing: Uninstall-Module -AllVersions works from the PSGallery
  #   package store, so a copy that was never installed from it (an image-baked
  #   copy, or one another admin owns) survives the removal and keeps shadowing
  #   the pin. Only a listing taken after the install can catch that.
  \$remaining = @(Get-Module -ListAvailable -Name \$moduleName)
  \$leftover = @(\$remaining | Where-Object { \$_.Version -ne \$requiredVersion })
  # WHY versions only: a second copy of the pin itself, at another scope, passes
  #   this check. That is narrower than what
  #   src/platforms/Windows/modules/setup/Invoke-PowerShellModuleSetup.ps1 removes,
  #   and it is left narrower on purpose: the defect this script fixes is a stale
  #   version beside the pin, not a duplicate of the pin.
  # WHY the guard and its throw share a line: the activation tool check reads
  #   these files line by line, and a line-leading throw reads to it as a bare
  #   external command. No other script under src/scripts carries one.
  if (\$leftover.Count -gt 0) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed, but other copies remain: ' + ((\$leftover | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase }) -join '; '); throw \$failure }
  Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is the only copy') -ForegroundColor Green
"
