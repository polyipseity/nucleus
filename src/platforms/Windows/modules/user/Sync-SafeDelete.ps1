<#
.SYNOPSIS
  Deploys Windows safe-delete shims (rip.exe copies) and converges the
  PowerShell recycling function.

.DESCRIPTION
  Safe-delete defense for Windows: PowerShell overrides rm/del/rd/erase/ri/
  Remove-Item with a .NET Recycle Bin function (in profile.ps1). For non-PowerShell
  contexts (cmd.exe, Git Bash, scripts, agents), rip.exe shims in
  %USERPROFILE%\.local\bin intercept all deletion commands.

  Layout this function converges:

    <USER root>\bin\rm.exe, del.exe, rd.exe, rmdir.exe, erase.exe, ri.exe
      deployed copies of rip.exe (from Scoop shims dir)
    %USERPROFILE%\.local\bin\rm.exe, del.exe, ...  PATH shims (copies)
    %USERPROFILE%\.local\bin\safe-delete-guard.cmd   launcher for the shared
      deletion policy, which Sync-HarnessBridge deploys into
      <USER root>\bin\filters
    <USER root>\state\safe-delete\shims.json   every deployed shim path and
      the rip.exe hash the deletion filter proves it against
    <USER root>\state\rip\graveyard   the rip graveyard, the path RIP_GRAVEYARD
      names (src\modules\lib\env-secrets.nix)

.PARAMETER Enabled
  Whether safe-delete shims should be enforced.

.PARAMETER RepoRoot
  Absolute path to the live repository root.

.PARAMETER UserRoot
  Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

.PARAMETER UserProfile
  Absolute path to the user profile (%USERPROFILE%).
#>

# The deletion words the deployed shims answer, shared by the copies and the
# manifest so the two lists cannot drift.
$script:SafeDeleteShimNames = @("del.exe", "erase.exe", "rd.exe", "ri.exe", "rm.exe", "rmdir.exe")

function Resolve-ClinkCommand {
  <#
  .SYNOPSIS
    Resolve the Clink executable from PATH, or return $null when it is absent.

  .DESCRIPTION
    Clink comes from the WinGet DSC entry chrisant996.Clink in
    src\hosts\Windows\system\packages.dsc.yml. Nothing in this repo adds a PATH
    entry for Clink, so whatever Clink's own installer put on PATH is the whole
    search: the probe is a best-effort presence check, not a guarantee, and a
    miss only costs the clink inject AutoRun and the Lua filter hook.

    Binary names, from the v1.9.35 release archive: clink.bat, clink_x64.exe,
    clink_x86.exe, clink_arm64.exe, and no clink.exe. So clink (which resolves
    to clink.bat) is tried first, clink_x64 second, and the first match wins.

  .OUTPUTS
    System.String. The resolved path, or $null when Clink is absent.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  foreach ($name in @('clink', 'clink_x64')) {
    # check-suppress:suppression_doc: clink may not be installed; absence is the expected case and is reported by the caller
    $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($null -ne $command) {
      return $command.Source
    }
  }
  return $null
}

function Get-SafeDeleteShimsManifestPath {
  <#
  .SYNOPSIS
    Returns the shim manifest path under a nucleus Windows USER root.

  .PARAMETER UserRoot
    Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

  .OUTPUTS
    System.String. Absolute path to state\safe-delete\shims.json.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$UserRoot
  )

  return Join-Path -Path (Join-Path -Path (Join-Path -Path $UserRoot -ChildPath "state") -ChildPath "safe-delete") -ChildPath "shims.json"
}

function Write-SafeDeleteShimsManifest {
  <#
  .SYNOPSIS
    Writes the shim manifest the deletion filter reads.

  .DESCRIPTION
    The deployed shims are copies of rip.exe rather than symlinks, so the filter
    cannot tell a deployed shim from any other file on PATH by its target. The
    manifest records every deployed copy and the SHA256 of the rip.exe they came
    from, so a replaced or edited copy stays unproven.

    Entries are ordered objects sorted by name then path, so repeated runs write
    identical bytes.

  .PARAMETER UserRoot
    Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

  .PARAMETER RipExe
    Absolute path to the rip.exe the shims were copied from.

  .PARAMETER BinDir
    Absolute path to the USER root bin directory holding the deployed copies.

  .PARAMETER ShimDir
    Absolute path to the PATH shim directory (%USERPROFILE%\.local\bin).

  .OUTPUTS
    None.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$UserRoot,

    [Parameter(Mandatory)]
    [string]$RipExe,

    [Parameter(Mandatory)]
    [string]$BinDir,

    [Parameter(Mandatory)]
    [string]$ShimDir
  )

  if (-not (Test-Path -LiteralPath $RipExe -PathType Leaf)) {
    throw "Write-SafeDeleteShimsManifest: rip.exe not found at '$RipExe'; refusing to write a manifest without its hash"
  }

  $ripHash = (Get-FileHash -LiteralPath $RipExe -Algorithm SHA256).Hash.ToLowerInvariant()
  $shims = @(
    foreach ($dir in @($BinDir, $ShimDir)) {
      foreach ($name in $script:SafeDeleteShimNames) {
        [pscustomobject]@{
          name = $name
          path = (Join-Path -Path $dir -ChildPath $name)
        }
      }
    }
  ) | Sort-Object -Property name, path

  $document = [ordered]@{
    version = 1
    ripHash = $ripHash
    shims   = @($shims | ForEach-Object { [ordered]@{ name = $_.name; path = $_.path } })
  }

  $manifestPath = Get-SafeDeleteShimsManifestPath -UserRoot $UserRoot
  $manifestDir = Split-Path -Path $manifestPath -Parent
  if (-not (Test-Path -LiteralPath $manifestDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $manifestDir -Force > $null
  }
  # Set-Content terminates the line, so the file stays byte-identical across runs.
  Set-Content -Path $manifestPath -Value ($document | ConvertTo-Json -Depth 5) -Encoding utf8
}

function Sync-SafeDelete {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$UserRoot,

    [Parameter(Mandatory)]
    [string]$UserProfile
  )

  $binDir = Join-Path -Path $UserRoot -ChildPath "bin"
  $shimDir = Join-Path -Path $UserProfile -ChildPath ".local\bin"
  $ripExe = Join-Path -Path (Get-NucleusScoopShimsDir) -ChildPath "rip.exe"
  $manifestPath = Get-SafeDeleteShimsManifestPath -UserRoot $UserRoot

  $shimNames = $script:SafeDeleteShimNames

  # Clink Lua filter for cmd.exe interception
  $clinkDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "clink"
  $clinkLua = Join-Path -Path $clinkDir -ChildPath "safedel.lua"
  $clinkLuaSource = Join-Path -Path $RepoRoot -ChildPath "src\platforms\Windows\modules\user\clink\safedel.lua"

  if (-not $Enabled) {
    foreach ($name in $shimNames) {
      $target = Join-Path -Path $shimDir -ChildPath $name
      if (Test-Path -LiteralPath $target) {
        # check-suppress:suppression_doc: shim may already be absent; idempotent cleanup.
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      }
    }
    if (Test-Path -LiteralPath $clinkLua) {
      # check-suppress:suppression_doc: lua file may already be absent; idempotent cleanup.
      Remove-Item -LiteralPath $clinkLua -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $manifestPath) {
      # check-suppress:suppression_doc: the manifest may already be absent; idempotent cleanup.
      Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
    return
  }

  if (-not (Test-Path -LiteralPath $ripExe)) {
    # A manifest without a rip.exe to hash would prove shims that can no longer be
    # checked, so the stale proof is removed with the binary that backed it.
    if (Test-Path -LiteralPath $manifestPath) {
      # check-suppress:suppression_doc: the manifest may already be absent; idempotent cleanup.
      Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
    Write-NucleusWarning -CommandName 'Sync-SafeDelete' "rip.exe not found at '$ripExe'; run Invoke-ScoopSetup first"
    return
  }

  # RIP_GRAVEYARD (src\modules\lib\env-secrets.nix) names this directory. An
  # elevated or scheduled session does not inherit the User-scope variable, so
  # the directory is created here instead of on the first deletion.
  $graveyardDir = Join-Path -Path (Join-Path -Path (Join-Path -Path $UserRoot -ChildPath "state") -ChildPath "rip") -ChildPath "graveyard"
  if (-not (Test-Path -LiteralPath $graveyardDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $graveyardDir -Force > $null
  }

  # Ensure directories exist
  if (-not (Test-Path -LiteralPath $binDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $binDir -Force > $null
  }
  if (-not (Test-Path -LiteralPath $shimDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $shimDir -Force > $null
  }

  foreach ($name in $shimNames) {
    # Deployed copy in USER root bin
    $deployedPath = Join-Path -Path $binDir -ChildPath $name
    Copy-Item -LiteralPath $ripExe -Destination $deployedPath -Force

    # PATH shim in .local\bin
    $shimPath = Join-Path -Path $shimDir -ChildPath $name
    Copy-Item -LiteralPath $ripExe -Destination $shimPath -Force
  }

  # The manifest is the proof the deletion filter reads, so it is written only
  # after every copy landed.
  Write-SafeDeleteShimsManifest -UserRoot $UserRoot -RipExe $ripExe -BinDir $binDir -ShimDir $shimDir

  # Deploy clink Lua filter
  if (-not (Test-Path -LiteralPath $clinkDir)) {
    # check-suppress:suppression_doc: directory creation output not needed.
    New-Item -ItemType Directory -Path $clinkDir -Force > $null
  }
  if (Test-Path -LiteralPath $clinkLuaSource) {
    Copy-Item -LiteralPath $clinkLuaSource -Destination $clinkLua -Force
  }

  # Clink auto-run: register clink inject in cmd.exe AutoRun
  $clinkExe = Resolve-ClinkCommand
  if ($clinkExe) {
    $autoRunKey = "HKCU:\Software\Microsoft\Command Processor"
    $clinkInject = "& `"$clinkExe`" inject"
    # check-suppress:suppression_doc: AutoRun value may not exist yet.
    $current = (Get-ItemProperty -Path $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
    if ($current -notlike "*clink*inject*") {
      $newVal = if ($current) { "$current & $clinkInject" } else { $clinkInject }
      Set-ItemProperty -Path $autoRunKey -Name AutoRun -Value $newVal -Type String
    }
  } else {
    # check-suppress:suppression_doc: clink is optional; the doskey AutoRun below still maps every deletion command to rip.exe
    Write-NucleusWarning -CommandName 'Sync-SafeDelete' 'clink not found on PATH; a clink on PATH enables the cmd.exe Lua hook, and without it the doskey AutoRun still maps del, erase, rd, rmdir, rm to rip.exe'
  }

  # Doskey fallback for vanilla cmd.exe (no clink)
  $doskeyCmd = Join-Path -Path $binDir -ChildPath "cmd_aliases.cmd"
  $doskeyContent = "@echo off`r`ndoskey del=rip.exe `$*`r`ndoskey erase=rip.exe `$*`r`ndoskey rd=rip.exe `$*`r`ndoskey rmdir=rip.exe `$*`r`ndoskey rm=rip.exe `$*`r`n"
  Set-Content -Path $doskeyCmd -Value $doskeyContent -Force

  # Register the doskey AutoRun unconditionally: clink may be absent, and a
  # clink that is present may still not load the Lua filter, so cmd.exe needs
  # this mapping either way. The cmd_aliases guard keeps re-runs idempotent.
  $autoRunKey = "HKCU:\Software\Microsoft\Command Processor"
  # check-suppress:suppression_doc: AutoRun value may not exist yet.
  $current = (Get-ItemProperty -Path $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
  if ($current -notlike "*cmd_aliases*") {
    $newVal = if ($current) { "$current & `"$doskeyCmd`"" } else { "`"$doskeyCmd`"" }
    Set-ItemProperty -Path $autoRunKey -Name AutoRun -Value $newVal -Type String
  }

  # Agent guard: a PATH shim around the one deletion policy, run in its --hook
  # mode. The policy file is the copy Sync-HarnessBridge deploys, so the shim, the
  # harness filters, and the POSIX safe-delete-guard command all execute the same
  # bytes instead of a per-platform pattern set that can drift.
  $guardPolicy = Join-Path -Path $binDir -ChildPath "filters\safe-delete.ts"
  $guardDest = Join-Path -Path $shimDir -ChildPath "safe-delete-guard.cmd"
  $guardContent = "@echo off`r`nbun run `"$guardPolicy`" --hook %*`r`n"
  Set-Content -Path $guardDest -Value $guardContent -Force

  # Git Bash: rm alias to rip
  $bashrc = Join-Path -Path $UserProfile -ChildPath ".bashrc"
  $bashrcSnippet = "# Nucleus safe-delete: deletion union -> rip (graveyard)`nif [[ `$- == *i* ]]; then alias rm='rip'; alias del='rip'; alias rd='rip'; alias rmdir='rip'; alias erase='rip'; alias ri='rip'; alias unlink='rip'; alias shred='rip'; echo '[SafeDelete] deletion commands -> rip. Use rip -u to undo.'; fi`n"
  if (Test-Path -LiteralPath $bashrc) {
    $content = Get-Content -LiteralPath $bashrc -Raw
    if ($content -notlike "*Nucleus safe-delete*") {
      Add-Content -Path $bashrc -Value $bashrcSnippet
    }
  } else {
    Set-Content -Path $bashrc -Value $bashrcSnippet
  }
}
