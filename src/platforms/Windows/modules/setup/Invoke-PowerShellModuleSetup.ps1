function Invoke-PowerShellModuleSetup {
  <#
  .SYNOPSIS
    Idempotently installs PowerShell modules pinned in the repository lockfile.

  .DESCRIPTION
    Reads the `pwsh` section of lockfile.json and installs each listed module at
    the pinned version. Modules already at the correct version are
    skipped. Missing or mismatched modules are installed or updated.

    This is additive-only: modules present but not in the lockfile are left
    untouched (no zap/uninstall). PowerShell modules are shared state with
    non-nucleus workflows, so removal would be destructive.

    Currently managed:
      - Pester — required by scripts/test.ps1 for Windows Pester test suites
      - powershell-yaml — required by scripts/check.ps1 for locked DSC validation
      - PSScriptAnalyzer — (managed via Nix HM activation on POSIX, installed
        here for Windows parity)

    Requires PowerShellGet to be available (built into PowerShell 5.1+ and
    pwsh 7+). Modules are installed at CurrentUser scope so no admin rights
    are needed.

  .EXAMPLE
    Invoke-PowerShellModuleSetup

  .NOTES
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  if (-not (Test-Path $lockfilePath)) {
    Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "lockfile.json not found at $lockfilePath"
    return
  }

  $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  $pwshModules = if ($lockfile.pwsh) { $lockfile.pwsh } else { @{} }

  if ($pwshModules.Count -eq 0) {
    return
  }

  foreach ($entry in $pwshModules.PSObject.Properties) {
    $moduleName = $entry.Name
    $requiredVersion = $entry.Value

    if ([string]::IsNullOrWhiteSpace($requiredVersion)) {
      Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName has no pinned version — skipping"
      continue
    }

    # Check if the correct version is already installed.
    $installed = Get-Module -ListAvailable -Name $moduleName | Where-Object { $_.Version -eq [Version]$requiredVersion } | Select-Object -First 1
    if ($installed) {
      continue
    }

    # Remove any existing version to avoid conflicts.
    $existing = Get-Module -ListAvailable -Name $moduleName | Select-Object -First 1
    if ($existing) {
      Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "removing $moduleName version $($existing.Version)..."
      Uninstall-Module -Name $moduleName -AllVersions -Force -ErrorAction Stop
    }

    Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "installing $moduleName version $requiredVersion..."
    Install-Module -Name $moduleName -RequiredVersion $requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  }
}
