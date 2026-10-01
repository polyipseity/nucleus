function Invoke-PowerShellModuleSetup {
  <#
  .SYNOPSIS
    Idempotently installs PowerShell modules pinned in the repository lockfile.
  .DESCRIPTION
    Reads the `psgallery` section of lockfile.json and installs each module at
    its pinned version; a {version, hash} pin uses only the version. A copy at or
    above the pin is removed first, whatever its scope, so none can shadow it. A
    copy below the pin is removed only under the per-user module path, which is
    the tree this module owns; a copy below the pin anywhere else stays, because
    it cannot shadow the pin and the OS image put it there. Additive only, since
    PowerShell modules are shared with non-nucleus workflows.
    After the install the pin is verified under the per-user module path, so an
    install that reports success without landing is a failure rather than a pass.
    A failure does not stop the run: it is recorded, the sweep continues, the
    other pins are still installed, and every failure is thrown once at the end.
    Deleting a copy outside the per-user module path takes ownership of the
    tree, grants this account full control and clears
    read-only, because a read-only file in an image-owned tree is denied for a
    reason an ACL grant does not address.
    Removing an image- or other-admin-owned copy needs elevation even though
    the pin installs at CurrentUser.
  .PARAMETER CurrentUserModulePath
    Overrides the resolved per-user module directory. The Pester suite points this
    at a temp tree, because a live resolution would name the real per-user
    directory of whichever host runs the suite.
  .NOTES
    Requires PowerShellGet (built into PowerShell 5.1+ and pwsh 7+).
  #>
  [CmdletBinding()]
  param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$CurrentUserModulePath
  )

  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  if (-not (Test-Path $lockfilePath)) {
    Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "lockfile.json not found at $lockfilePath"
    return
  }

  $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  $psGalleryModules = if ($lockfile.psgallery) { $lockfile.psgallery } else { @{} }

  if ($psGalleryModules.Count -eq 0) {
    return
  }

  # WHY resolved rather than read from PSModulePath: PowerShellGet decides where
  #   Install-Module -Scope CurrentUser writes from the Documents folder and the
  #   PowerShell edition, and never consults $env:PSModulePath at all. Reading that
  #   variable by position is what had this function reject every pin it had just
  #   installed on the GitHub runner, where SQL Server tooling appends
  #   C:\Program Files\Microsoft SQL Server\<version>\Tools\PowerShell\Modules\ and
  #   that entry is the last one.
  # Source: https://github.com/PowerShell/PowerShellGetv2/blob/master/src/PowerShellGet/private/modulefile/PartOne.ps1
  if ([string]::IsNullOrWhiteSpace($CurrentUserModulePath)) {
    $CurrentUserModulePath = Get-CurrentUserModulePath
  }

  $convergenceFailures = @()

  foreach ($entry in $psGalleryModules.PSObject.Properties) {
    $moduleName = $entry.Name
    $pin = $entry.Value
    $requiredVersion = if ($pin -is [string]) { $pin } else { $pin.version }

    if ([string]::IsNullOrWhiteSpace($requiredVersion)) {
      Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName has no pinned version, skipping"
      continue
    }

    $existing = @(Get-Module -ListAvailable -Name $moduleName)
    $converged = @($existing | Where-Object {
        $_.Version -eq [Version]$requiredVersion -and
        $_.ModuleBase -like "$currentUserModulePath*"
      })
    # WHY the converged copy is spared: it is the pin, in the scope this module
    # installs to, so removing it would force a PSGallery round trip on every run
    # to put back what was already right. The version floor below still takes out
    # a machine-scope copy of the pinned version, which is not the scope this
    # module owns and outranks the pin in the module path.
    # WHY a copy below the pin is a target only under the per-user path: that is
    # the tree this module owns, and a stale copy beside the pin is what leaves
    # Get-Module -ListAvailable reporting two versions of the same module. Outside
    # that path the copy stays, because it cannot shadow the pin and this
    # repository has no reason to delete a module the image ships. That is the
    # Pester 3.4.0 the GitHub runner image carries under Program Files beside a
    # 6.2.0 pin, and trying to delete it is what turned that runner red before
    # any check or test step ran.
    # WHY a copy exactly at the pin stays a target: PowerShell breaks a version
    # tie by path order, so a copy of the pin at a scope this module does not own
    # outranks the per-user one.
    # WHY derived from $converged rather than testing the same predicate twice:
    #   both lists come from the same listing, so the converged copy is guaranteed
    #   to be spared, and a second copy of the rule is the one way that could stop
    #   holding.
    $sweepTargets = @($existing | Where-Object {
        if ($converged -contains $_) { return $false }

        return ($_.Version -ge [Version]$requiredVersion) -or ($_.ModuleBase -like "$currentUserModulePath*")
      })

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
        # removal that fails is recorded rather than left to look like success.
        if (-not (Test-Path $copy.ModuleBase)) {
          continue
        }

        # WHY the try: a denied Remove-Item used to end the module at the first
        # stubborn copy, so the copies behind it stayed and the pin below was
        # never installed, which is what cost the CI runner its 6.2.0 pin.
        # Recording the failure and moving on keeps the rest of the sweep and the
        # install reachable; the collected failures are thrown once at the end.
        try {
          # WHY both steps only outside the per-user path: a copy there is ours,
          # so it is already removable and already writable, and both steps would
          # be a permission and an attribute change with nothing behind them. A
          # copy anywhere else came from the image or from another admin, so it
          # may be owned by TrustedInstaller, which is what made Remove-Item fail
          # on the CI runner image, and it may carry read-only attributes that an
          # ACL grant does not clear.
          if ($copy.ModuleBase -notlike "$currentUserModulePath*") {
            Enable-ModuleTreeRemoval -Path $copy.ModuleBase
            # WHY after the grant: clearing an attribute needs the rights the
            # grant supplies, and the grant alone leaves the attribute in place.
            Clear-ModuleTreeReadOnlyAttribute -Path $copy.ModuleBase
          }

          Remove-Item -Path $copy.ModuleBase -Recurse -Force -ErrorAction Stop
          Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "removed $moduleName directory at $($copy.ModuleBase)"
        } catch {
          $failureMessage = $_.Exception.Message
          # WHY the evidence: "Access ... is denied" names neither the read-only
          # attribute nor the process holding the file, and choosing between them
          # on a guess sends the reader after the wrong thing. What the probes
          # prove is reported; the rest is reported as unknown.
          $evidence = Get-ModuleRemovalDiagnosis -Path $copy.ModuleBase -Failure $failureMessage
          $convergenceFailures += "$moduleName $($copy.Version) at $($copy.ModuleBase): $failureMessage. Evidence: $evidence"
          # WHY Continue: the caller runs under $ErrorActionPreference Stop, where
          # an unsuppressed Write-Error would end the very sweep this catch exists
          # to keep going.
          Write-NucleusError -CommandName 'Invoke-PowerShellModuleSetup' "could not remove the $moduleName $($copy.Version) copy at $($copy.ModuleBase): $failureMessage. Evidence: $evidence" -ErrorAction Continue
        }
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

    # WHY a second listing: the install is the only step that can put the pin
    # under the per-user path, so the listing taken before it cannot prove
    # anything about the result.
    $available = @(Get-Module -ListAvailable -Name $moduleName)
    $installed = @($available | Where-Object {
        $_.Version -eq [Version]$requiredVersion -and
        $_.ModuleBase -like "$currentUserModulePath*"
      })
    if ($installed.Count -gt 0) {
      Write-NucleusInfo -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName $requiredVersion is installed at CurrentUser scope"
      continue
    }

    # WHY the found list in the message: "not installed" alone sends the reader
    # back to the same listing that already said so. What was found names the
    # copy that took the slot, which is the answer the reader needs.
    $found = (@($available | ForEach-Object { "$($_.Version) at $($_.ModuleBase)" }) -join '; ')
    if (-not $found) { $found = 'no copy of this module' }
    $convergenceFailures += "$moduleName $($requiredVersion): not installed under $currentUserModulePath after the install; found: $found"
    # WHY Continue: the caller runs under $ErrorActionPreference Stop, where an
    # unsuppressed Write-Error would end the sweep over the remaining pins.
    Write-NucleusError -CommandName 'Invoke-PowerShellModuleSetup' "$moduleName $requiredVersion is not installed under $currentUserModulePath; found: $found" -ErrorAction Continue
  }

  # WHY here and not at the first failure: every remaining copy was still swept
  # and every reachable pin still installed before this point, so one throw
  # carries the whole picture instead of hiding the copies behind the first one
  # that failed.
  if ($convergenceFailures.Count -gt 0) {
    $failureReport = $convergenceFailures -join [Environment]::NewLine
    throw "Invoke-PowerShellModuleSetup: $($convergenceFailures.Count) module convergence failure(s), so this host is not fully converged. Every sweepable copy was still removed and every reachable pin still installed. Failures:$([Environment]::NewLine)$failureReport"
  }
}


function Get-CurrentUserModulePath {
  <#
  .SYNOPSIS
    Resolves the per-user PowerShell module directory of the running account.

  .DESCRIPTION
    PowerShellGet derives the directory that Install-Module -Scope CurrentUser writes
    to from [Environment]::GetFolderPath('MyDocuments') and the PowerShell edition,
    and never from $env:PSModulePath. This mirrors that computation so a caller can
    predict where a pin landed and verify it, which is the only reason the value is
    worth resolving.

    The edition decides the leaf directory. PowerShell 7 uses PowerShell\Modules and
    Windows PowerShell 5.1 uses WindowsPowerShell\Modules, and both are reachable
    because the Windows host orchestrator can be run by hand under either.

    The empty-documents-root branch mirrors PowerShellGet's own fallback rather than
    failing, because a prediction that disagrees with the installer is the same
    defect in a different place.

  .PARAMETER DocumentsRoot
    The Documents folder to resolve under. Defaults to the running account's, which
    moves with folder redirection and with OneDrive.

  .PARAMETER PowerShellEdition
    The PowerShell edition, which selects the leaf directory name. Defaults to the
    running session's.

  .OUTPUTS
    System.String. The CurrentUser modules directory.

  .EXAMPLE
    Get-CurrentUserModulePath

  .EXAMPLE
    Get-CurrentUserModulePath -DocumentsRoot 'C:\Users\runneradmin\Documents' -PowerShellEdition 'Core'

  .NOTES
    Windows only. PowerShellGet resolves the non-Windows CurrentUser path through
    [Platform]::SelectProductNameForDirectory('USER_MODULES') instead.

    Sources:
    https://github.com/PowerShell/PowerShellGetv2/blob/master/src/PowerShellGet/private/modulefile/PartOne.ps1
    https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath
  #>
  [CmdletBinding()]
  param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$DocumentsRoot,

    [Parameter()]
    [AllowEmptyString()]
    [string]$PowerShellEdition
  )

  if ([string]::IsNullOrWhiteSpace($DocumentsRoot)) {
    # WHY the catch: a locked-down or headless profile can make the call fail, and
    #   PowerShellGet treats that as an empty path rather than an error. Matching it
    #   is what keeps this prediction pointing at the same directory.
    try {
      $DocumentsRoot = [Environment]::GetFolderPath('MyDocuments')
    } catch {
      $DocumentsRoot = ''
    }
  }

  if ([string]::IsNullOrWhiteSpace($PowerShellEdition)) {
    $PowerShellEdition = $PSVersionTable.PSEdition
  }

  # WHY the edition rather than $PSHOME's path shape: the edition is the value the
  #   two supported hosts differ on, and $IsWindows does not exist under 5.1.
  if ($PowerShellEdition -eq 'Desktop') {
    $powerShellRootName = 'WindowsPowerShell'
    $profileRoot = $env:USERPROFILE
  } else {
    $powerShellRootName = 'PowerShell'
    $profileRoot = $HOME
  }

  # WHY the guard inside the branch: the profile root is only consulted when the
  #   Documents folder is unavailable, so a host that resolved Documents never
  #   depends on it.
  $powerShellRoot = if ([string]::IsNullOrWhiteSpace($DocumentsRoot)) {
    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
      throw "Get-CurrentUserModulePath: neither the Documents folder nor the user profile root resolved, so the CurrentUser module path is unknown. PowerShellEdition='$PowerShellEdition'"
    }
    Join-Path $profileRoot "Documents\$powerShellRootName"
  } else {
    Join-Path $DocumentsRoot $powerShellRootName
  }

  return Join-Path $powerShellRoot 'Modules'
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


function Clear-ModuleTreeReadOnlyAttribute {
  <#
  .SYNOPSIS
    Clears the read-only attribute across a module tree that is about to be deleted.

  .DESCRIPTION
    A module tree that came from the OS image can carry the read-only attribute
    on its files. Taking ownership and granting full control does not clear that
    attribute, so Remove-Item is denied on the file and says the same
    "Access to the path ... is denied" a permission problem would, with nothing
    in the output to tell the two apart. attrib -R over the tree is idempotent,
    so a tree that never had the attribute costs one fast native call and
    changes nothing.

  .PARAMETER Path
    The module directory to clear the read-only attribute in.

  .EXAMPLE
    Clear-ModuleTreeReadOnlyAttribute -Path 'C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0'

  .NOTES
    Reports a nonzero exit as a warning naming the tree and does not throw: the
    delete may still succeed, and a delete that fails is reported against the
    copy it was about.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  # WHY /S /D: the attribute is on the files inside the tree rather than on the
  #   directory entry, so clearing the directory alone leaves the delete denied
  #   on those files.
  $clearResult = (& attrib.exe -R $Path /S /D 2>&1) | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusWarning -CommandName 'Invoke-PowerShellModuleSetup' "could not clear the read-only attribute on $Path : $clearResult"
  }
}


function Get-ModuleRemovalDiagnosis {
  <#
  .SYNOPSIS
    States what provably blocked a module copy from being deleted.

  .DESCRIPTION
    A denied Remove-Item names neither the read-only attribute nor the process
    holding the file, and a guess between the two sends the reader after the
    wrong one. This checks both cheaply and reports what it established: whether
    the tree still carries the read-only attribute, and whether the file named
    in the error can be opened exclusively. Anything it could not establish is
    reported as unknown rather than guessed.

  .PARAMETER Path
    The module directory the failed removal was about.

  .PARAMETER Failure
    The exception message the failed removal produced. Its first quoted string
    is read as the blocking file, which is how both the .NET and the PowerShell
    access errors name it.

  .EXAMPLE
    Get-ModuleRemovalDiagnosis -Path 'C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0' -Failure $ErrorRecord.Exception.Message

  .NOTES
    Returns one sentence. No cause it did not check is ever named.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Failure
  )

  $findings = [System.Collections.Generic.List[string]]::new()
  $causeFound = $false

  if (Test-Path -LiteralPath $Path) {
    $attributeFinding = ''
    try {
      $treeAttributes = (Get-Item -LiteralPath $Path -Force).Attributes
      if ($treeAttributes -band [IO.FileAttributes]::ReadOnly) {
        $attributeFinding = "the directory still carries the read-only attribute ($treeAttributes)"
        $causeFound = $true
      }
    } catch {
      $attributeFinding = "the directory attributes could not be read ($($_.Exception.Message))"
    }
    if ($attributeFinding) {
      $findings.Add($attributeFinding)
    }
  } else {
    $findings.Add('the directory is already gone, so the delete stopped part way through the tree')
  }

  $blockingFile = ''
  if ($Failure -match "'([^']*)'") {
    $blockingFile = $Matches[1]
  }

  # WHY an exclusive open rather than a process walk: opening with no sharing
  #   is one call and answers the only question that matters, which is whether
  #   something holds the file. Walking process modules is slow, needs
  #   elevation per process, and is denied for most of them anyway.
  if ($blockingFile -and (Test-Path -LiteralPath $blockingFile)) {
    $handleFinding = ''
    $stream = $null
    try {
      $stream = [System.IO.File]::Open($blockingFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      $handleFinding = 'nothing holds the file open exclusively'
    } catch [System.IO.FileNotFoundException] {
      # WHY named separately: a sharing violation and a missing file are both
      # IOException, and reporting a missing file as a held handle would be a
      # cause nobody proved.
      $handleFinding = 'the file the error named is no longer there, so the delete stopped part way through the tree'
    } catch [System.IO.DirectoryNotFoundException] {
      $handleFinding = 'the directory the error named is no longer there, so the delete stopped part way through the tree'
    } catch [System.IO.IOException] {
      $handleFinding = 'another process holds an open handle on it'
      $causeFound = $true
    } catch [System.UnauthorizedAccessException] {
      # WHY it names both and picks neither: a write open is refused by an ACL
      # and by a surviving read-only attribute alike, and the open cannot tell
      # the two apart, so the refusal is what gets reported.
      $handleFinding = 'this account is refused write access to the file itself, which a surviving read-only attribute alone also causes'
      $causeFound = $true
    } catch {
      $handleFinding = "the file could not be probed ($($_.Exception.Message))"
    } finally {
      if ($stream) {
        $stream.Dispose()
      }
    }
    $findings.Add($handleFinding)
  }

  if (-not $causeFound) {
    $findings.Add('no cause could be established on this host')
  }

  return ($findings -join '; ')
}
