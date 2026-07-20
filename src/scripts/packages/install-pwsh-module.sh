# Install/update a PowerShell module to a pinned version.
# Variables below are substituted via Nix replaceStrings at build time.
set -euo pipefail

_pwsh="__PWSH_BIN__"
_module="__MODULE_NAME__"
_version="__MODULE_VERSION__"

if [ ! -x "$_pwsh" ] || [ -z "$_version" ]; then
  exit 0
fi

"$_pwsh" -NoProfile -Command "
  \$requiredVersion = '$_version'
  \$installed = Get-Module -ListAvailable -Name $_module | Select-Object -First 1
  if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
    if (\$installed) {
      Write-Host 'install-pwsh-module: removing $_module version '\$(\$installed.Version)'...' -ForegroundColor Yellow
      Uninstall-Module -Name $_module -AllVersions -Force
    }
    Write-Host 'install-pwsh-module: installing $_module version '\$requiredVersion'...' -ForegroundColor Cyan
    Install-Module -Name $_module -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  }
"
