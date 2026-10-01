#!/usr/bin/env bash
# Install a PowerShell module at a pinned version for the current user, so the pin
# is the only copy PowerShell loads. Args: <pwsh-binary> <module-name>
# <module-version> [<privilege-command>], where the fourth is a resolved sudo path
# or empty and is needed only when a copy has to be removed.
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

# WHY the skips stay non-fatal: a host with no pwsh yet, or a lockfile with no
#   pin for this module, has nothing to converge to. Each one names itself,
#   because a silent exit left no way to tell a skip from an entry that never ran.
# WHY printf rather than say: this script sources no library, and the prefix
#   matches what the program below writes through Write-Host.
if [ ! -x "$_ipm_pwsh" ]; then
  printf '%s\n' "install-pwsh-module: pwsh is not at $_ipm_pwsh, nothing to converge for $_ipm_module"
  exit 0
fi
if [ -z "$_ipm_version" ]; then
  printf '%s\n' "install-pwsh-module: lockfile pins no version for $_ipm_module, nothing to converge"
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
  # WHY the removal program travels inside this one: it is handed the version
  #   and path pairs the listing below produced. It runs in its own process
  #   because a privileged copy cannot be removed from this one, and
  #   -ErrorAction Stop makes a refused removal abort rather than leave a shadow
  #   behind.
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
  \$target = @(\$_ -split '\|', 2)
  \$version = \$target[0]
  \$base = \$target[1]
  # WHY the base joins the module path before the removal: this child runs as
  #   root, and a root module path holds no entry for the user's module tree, so
  #   Uninstall-Module would report the version as not installed and delete
  #   nothing.
  \$env:PSModulePath = \$base + [IO.Path]::PathSeparator + \$env:PSModulePath
  Write-Host ('install-pwsh-module: elevated removal of ' + \$moduleName + ' ' + \$version + ' at ' + \$base) -ForegroundColor Yellow
  Uninstall-Module -Name \$moduleName -RequiredVersion \$version -Force -ErrorAction Stop
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
  # WHY the owned set: the per-user tree is where this script installs, so every
  #   copy in it is nucleus state, whether it is the pin or a leftover.
  \$owned = @(\$available | Where-Object { \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY the sweep reaches below the pin inside the owned tree and nowhere else:
  #   a stale copy there is what leaves PSScriptAnalyzer 1.20.0 sitting beside a
  #   1.25.0 pin. Outside it PowerShell never loads a version below the pin, and
  #   the Windows runner image ships Pester 3.4.0 whose deletion turned that
  #   runner red.
  \$shadowing = @(\$available | Where-Object { \$converged -notcontains \$_ -and (\$_.Version -ge \$requiredVersion -or \$owned -contains \$_) })
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
    if (-not \$privilegeCommand) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' cannot be converged: ' + ((@(\$shadowing | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase })) -join '; ') + ' is stale or can shadow the pin and no privilege command was supplied to remove it'; throw \$failure }
    Write-Host ('install-pwsh-module: removing ' + \$shadowing.Count + ' stale or shadowing ' + \$moduleName + ' version(s) as ' + \$privilegeCommand + '...') -ForegroundColor Yellow
    \$shadowTargets = @(\$shadowing | ForEach-Object { '' + \$_.Version + '|' + \$_.ModuleBase } | Select-Object -Unique)
    # WHY the call operator rather than a pipeline: the targets are arguments to
    #   the child, and a native command takes them the way it takes any argv.
    & \$privilegeCommand \$pwshBinary -NoProfile -CommandWithArgs \$removalProgram \$moduleName @(\$shadowTargets)
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
      \$failure = 'install-pwsh-module: could not remove ' + \$copies + ', which is stale or can shadow ' + \$moduleName + ' ' + \$requiredVersion + '; remove it with privilege the current user lacks, then re-run'; throw \$failure
    }
  }
  Write-Host ('install-pwsh-module: installing ' + \$moduleName + ' ' + \$requiredVersion + '...') -ForegroundColor Cyan
  Install-Module -Name \$moduleName -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  # WHY the fresh listing: Uninstall-Module -RequiredVersion works from the
  #   PSGallery package store, so a copy never installed from it (image-baked, or
  #   owned by another admin) survives the removal and keeps shadowing the pin.
  \$remaining = @(Get-Module -ListAvailable -Name \$moduleName)
  # WHY the pin is re-derived here: the listing after the install holds different
  #   objects, so the set membership has to come from it.
  \$remainingPin = @(\$remaining | Where-Object { \$_.Version -eq \$requiredVersion -and \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY this check exists: Install-Module can return without leaving the pin in
  #   place, and a check that only asks what could shadow the pin reads an
  #   empty listing as success.
  if (\$remainingPin.Count -eq 0) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is not installed under ' + \$currentUserModulePath + ' after the install reported success'; throw \$failure }
  \$ownedRemaining = @(\$remaining | Where-Object { \$_.ModuleBase -like (\$currentUserModulePath + '*') })
  # WHY the leftover set takes the same shape as the sweep: a stale copy the
  #   sweep could not remove is the same defect as one that shadows the pin, and
  #   a copy outside the owned tree stays none of this script's business.
  \$leftover = @(\$remaining | Where-Object { \$remainingPin -notcontains \$_ -and (\$_.Version -ge \$requiredVersion -or \$ownedRemaining -contains \$_) })
  if (\$leftover.Count -gt 0) { \$failure = 'install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed, but other copies remain: ' + ((\$leftover | ForEach-Object { '' + \$_.Version + ' at ' + \$_.ModuleBase }) -join '; '); throw \$failure }
  Write-Host ('install-pwsh-module: ' + \$moduleName + ' ' + \$requiredVersion + ' is installed and no copy can shadow it') -ForegroundColor Green
"
