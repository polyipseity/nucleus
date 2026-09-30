function Invoke-PowerShellModuleSetup {
  <#
  .SYNOPSIS
    Idempotently installs PowerShell modules pinned in the repository lockfile.

  .DESCRIPTION
    Reads the `psgallery` section of lockfile.json and installs each listed
    module at the pinned version. A pin is either a version string or a
    {version, hash} object; only the version is used here. Every discovered copy
    of a listed module is removed first, whatever its version or scope, so a
    stale copy cannot shadow the pin. The pin is then installed under CurrentUser
    unless a copy at that version is already there.

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
  # WHY no nupkg hash check here: Install-Module installs from PSGallery by name
  # and cannot install a verified local nupkg, so hashing a separate download
  # would not cover the artifact that lands on disk. The {hash} pin is consumed
  # by the hash-pinned declarative module path instead; this installer is
  # version-pinned only.
  $psGalleryModules = if ($lockfile.psgallery) { $lockfile.psgallery } else { @{} }

  if ($psGalleryModules.Count -eq 0) {
    return
  }

  # WHY the last entry: PowerShellGet installs CurrentUser scope into the per-user
  #   module path, which is the last entry of PSModulePath on every platform this
  #   module runs on. Deriving it beats hardcoding the Windows PowerShell 5 path,
  #   which PowerShell 7 no longer uses.
  $currentUserModulePath = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })[-1]

  foreach ($entry in $psGalleryModules.PSObject.Properties) {
    $moduleName = $entry.Name
    $pin = $entry.Value
    # A psgallery pin is either a version string or a {version, hash} object.
    $requiredVersion = if ($pin -is [string]) { $pin } else { $pin.version }

    if ([string]::IsNullOrWhiteSpace($requiredVersion)) {
      Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName has no pinned version — skipping"
      continue
    }

    # Remove every copy that is present, not just the first.
    # WHY the whole set: Get-Module -ListAvailable returns one entry per version
    # AND per scope, and a runner image carrying Pester 5.9.0 beside 3.4.0 leaves
    # the second copy in the module path. Removing one entry leaves the other
    # exactly where it was, where it shadows the pin and makes the Install-Module
    # below warn that 3.4.0 is unsupported.
    # WHY the sweep runs before anything is skipped: the old short-circuit sat
    # ahead of this block, so a host that already had the pin never removed the
    # stale copy beside it, and a stale copy shadows the pin in the module path.
    $existing = @(Get-Module -ListAvailable -Name $moduleName)
    $converged = @($existing | Where-Object {
        $_.Version -eq [Version]$requiredVersion -and
        $_.ModuleBase -like "$currentUserModulePath*"
      })
    # WHY the directories and not Uninstall-Module: -AllVersions works from the
    # PSGallery package store, where the name is one package, so it cannot spare
    # the converged copy and would take it along with the stale ones. Removing
    # each copy by its own path is the only selective form available, and it also
    # covers a runner-image copy that has no package record to uninstall through.
    # WHY the converged copy is spared: it is the pin, in the scope this module
    # installs to, so removing it would force a PSGallery round trip on every run
    # to put back what was already right. Every other copy goes, including a
    # machine-scope copy of the pinned version, which is not the scope this module
    # owns and can shadow the pin it is.
    # WHY derived from $converged rather than testing the same predicate twice:
    #   the two lists have to partition $existing exactly, and a second copy of the
    #   rule is the one way they could stop doing that.
    $sweepTargets = @($existing | Where-Object { $converged -notcontains $_ })

    if ($sweepTargets.Count -gt 0) {
      Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "removing $($sweepTargets.Count) conflicting version(s) of $moduleName..."

      foreach ($copy in $sweepTargets) {
        # WHY the skip: a copy Uninstall-Module already took on an earlier run is
        # registered in Get-Module but gone from disk, so its absence is the
        # converged state rather than a failure. Anything still there is removed
        # below, and a removal that fails throws rather than leaving a copy behind.
        if (-not (Test-Path $copy.ModuleBase)) {
          continue
        }
        Remove-Item -Path $copy.ModuleBase -Recurse -Force -ErrorAction Stop
        Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "removed $moduleName directory at $($copy.ModuleBase)"
      }
    }

    # Keyed on the pin that survived the sweep, not on whether there was anything
    # to sweep: a host that already had the pin in the right place alongside a
    # stale copy has just had that copy removed and needs nothing else.
    if ($converged.Count -gt 0) {
      Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName $requiredVersion already converged at CurrentUser scope - skipping install"
      continue
    }

    Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "installing $moduleName version $requiredVersion..."
    Install-Module -Name $moduleName -RequiredVersion $requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
  }
}
