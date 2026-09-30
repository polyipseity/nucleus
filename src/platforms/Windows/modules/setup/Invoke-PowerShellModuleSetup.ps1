function Invoke-PowerShellModuleSetup {
  <#
  .SYNOPSIS
    Idempotently installs PowerShell modules pinned in the repository lockfile.

  .DESCRIPTION
    Reads the `psgallery` section of lockfile.json and installs each listed
    module at the pinned version. A pin is either a version string or a
    {version, hash} object; only the version is used here. Every discovered copy
    of a listed module at or above the pin is removed first, whatever its scope,
    so no copy can shadow the pin. A copy below the pin is left where it is:
    PowerShell loads the highest version available, so such a copy is inert. The
    pin is then installed under CurrentUser unless a copy at that version is
    already there.

    This is additive-only: modules present but not in the lockfile are left
    untouched (no zap/uninstall). PowerShell modules are shared state with
    non-nucleus workflows, so removal would be destructive.

    Currently managed:
      - Pester — required by scripts/test.ps1 for Windows Pester test suites
      - powershell-yaml — required by scripts/check.ps1 for locked DSC validation
      - PSScriptAnalyzer — (managed via Nix HM activation on POSIX, installed
        here for Windows parity)

    Requires PowerShellGet to be available (built into PowerShell 5.1+ and
    pwsh 7+). Modules are installed at CurrentUser scope, but removing a copy
    that the image or another admin installed does need elevation, because that
    copy can be owned by TrustedInstaller.

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

    # Remove every copy that is not converged and can still shadow the pin.
    # WHY the whole set: Get-Module -ListAvailable returns one entry per version
    # AND per scope, and a host carrying two copies at or above the pin leaves
    # the second one in the module path. Removing one entry leaves the other
    # exactly where it was, where it still shadows the pin.
    # WHY the sweep runs before anything is skipped: the old short-circuit sat
    # ahead of this block, so a host that already had the pin never removed the
    # copy beside it that could shadow it.
    $existing = @(Get-Module -ListAvailable -Name $moduleName)
    $converged = @($existing | Where-Object {
        $_.Version -eq [Version]$requiredVersion -and
        $_.ModuleBase -like "$currentUserModulePath*"
      })
    # WHY the directories and not Uninstall-Module: -AllVersions works from the
    # PSGallery package store, where the name is one package, so it cannot spare
    # the converged copy and would take it along with the rest. Removing each copy
    # by its own path is the only selective form available, and it also covers a
    # copy that has no package record to uninstall through.
    # WHY the converged copy is spared: it is the pin, in the scope this module
    # installs to, so removing it would force a PSGallery round trip on every run
    # to put back what was already right. The version floor below still takes out
    # a machine-scope copy of the pinned version, which is not the scope this
    # module owns and outranks the pin in the module path.
    # WHY at or above the pin rather than merely different from it: PowerShell
    # loads the highest version available, so a copy below the pin is inert and
    # cannot shadow it, and this repository has no reason to delete a module the
    # Windows image ships. That is the Pester 3.4.0 the GitHub runner image
    # carries under Program Files beside a 6.2.0 pin, and trying to delete it is
    # what turned that runner red before any check or test step ran.
    # WHY a copy exactly at the pin stays a target: PowerShell breaks a version
    # tie by path order, so a copy of the pin at a scope this module does not own
    # outranks the per-user one.
    # WHY derived from $converged rather than testing the same predicate twice:
    #   both lists come from the same listing, so the converged copy is guaranteed
    #   to be spared, and a second copy of the rule is the one way that could stop
    #   holding.
    $sweepTargets = @($existing | Where-Object { $_.Version -ge [Version]$requiredVersion -and $converged -notcontains $_ })

    if ($sweepTargets.Count -gt 0) {
      Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "removing $($sweepTargets.Count) conflicting version(s) of $moduleName..."

      # WHY unload first: a copy already loaded into this session keeps its files
      # open, and the delete below then fails on a locked file. The macOS
      # bootstrap log shows the same module reported as in use, where the removal
      # was skipped and a stale copy survived beside the pin.
      if (Get-Module -Name $moduleName) {
        Remove-Module -Name $moduleName -Force
      }

      foreach ($copy in $sweepTargets) {
        # WHY the skip: a copy an earlier run already took is still listed by
        # Get-Module but gone from disk, so its absence is the converged state
        # rather than a failure. Anything still there is removed below, and a
        # removal that fails throws rather than leaving a copy behind.
        if (-not (Test-Path $copy.ModuleBase)) {
          continue
        }

        # WHY ownership only outside the per-user path: a copy there is ours, so
        # it is already removable. A copy anywhere else came from the image or
        # from another admin and may be owned by TrustedInstaller, which is what
        # made Remove-Item fail on the CI runner image.
        if ($copy.ModuleBase -notlike "$currentUserModulePath*") {
          Enable-ModuleTreeRemoval -Path $copy.ModuleBase
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


function Enable-ModuleTreeRemoval {
  <#
  .SYNOPSIS
    Makes a module tree this process is about to delete actually deletable.

  .DESCRIPTION
    A module copy found outside the per-user module path was put there by the OS
    image or by another administrator, and may be owned by TrustedInstaller.
    Remove-Item then fails with "Access to the path ... is denied" even for an
    elevated administrator. Taking ownership and granting this account full
    control over the tree is what makes the removal possible at all.

    Only call this for a tree this repository is removing on purpose. Granting
    full control is a real permission change, not a cleanup step.

  .PARAMETER Path
    The module directory to make removable.

  .EXAMPLE
    Enable-ModuleTreeRemoval -Path 'C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0'

  .NOTES
    Requires elevation, which the Windows bootstrap already runs under.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  # WHY this principal: it is the account doing the delete, and it is the value
  #   the delete-protection helper in this repository already uses.
  $principal = "$env:USERDOMAIN\$env:USERNAME"

  # WHY /A: hand ownership to the Administrators group, which an elevated
  #   activation belongs to, rather than to the interactive user, which may be
  #   a different account on a shared host.
  $takeownResult = (& takeown.exe /F $Path /A /R /D Y 2>&1) | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError -CommandName 'Invoke-PowerShellModuleSetup' "could not take ownership of $Path : $takeownResult"
    throw
  }

  # WHY (OI)(CI) and /T: a module is consumed through the files inside its
  #   directory, so a grant on the directory entry alone would still leave the
  #   contents undeletable.
  $grantResult = (& icacls $Path /grant "${principal}:(OI)(CI)F" /T 2>&1) | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError -CommandName 'Invoke-PowerShellModuleSetup' "could not grant delete access to $Path : $grantResult"
    throw
  }
}
