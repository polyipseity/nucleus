#!/usr/bin/env bash
# Install/update a PowerShell module to a pinned version.
# CLI args: pwsh_bin module_name module_version
set -euo pipefail


_ipm_pwsh="$1"
_ipm_module="$2"
_ipm_version="$3"

if [ ! -x "$_ipm_pwsh" ] || [ -z "$_ipm_version" ]; then
  exit 0
fi

"$_ipm_pwsh" -NoProfile -Command "
  \$requiredVersion = '$_ipm_version'
  \$installed = Get-Module -ListAvailable -Name $_ipm_module | Select-Object -First 1
  if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
    if (\$installed) {
      Write-Host 'install-pwsh-module: removing $_ipm_module version '\$(\$installed.Version)'...' -ForegroundColor Yellow
      Uninstall-Module -Name $_ipm_module -AllVersions -Force
    }
    Write-Host 'install-pwsh-module: installing $_ipm_module version '\$requiredVersion'...' -ForegroundColor Cyan
    Install-Module -Name $_ipm_module -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  }
"
