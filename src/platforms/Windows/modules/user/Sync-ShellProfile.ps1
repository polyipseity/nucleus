function Sync-ShellProfile {
  <#
  .SYNOPSIS
    Converges a managed shell-parity block in PowerShell profile files.

  .DESCRIPTION
    Writes or removes a bounded managed block in the CurrentUserCurrentHost and
    CurrentUserAllHosts profiles. The managed content comes from the shared
    cross-platform profile src/scripts/shell/profile.ps1, which is also embedded
    by src/modules/pwsh.nix on POSIX hosts, so shell parity has one source.

    Also converges the PSScriptAnalyzerSettings reference symlink next to the
    CurrentUserCurrentHost profile, mirroring POSIX pwsh.nix (method 1).

    Disabling removes only the managed block and the settings symlink.

  .PARAMETER Enabled
    Mandatory: true applies the block, false removes it.

  .NOTES
    Environment variables: NUCLEUS_REPO_ROOT: must be set by caller (apply.ps1
    exports it) when the settings symlink is enabled.
    Exit codes: 0 on success; non-zero on failure
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory = $false)]
    [string]$User,

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot
  )

  # ref: comment-annotations.instructions.md -- Category 2 sentinel convention
  # (nucleus-managed framing; brackets reserved for machine-managed regions).
  $managedBlockStart = '# >>> begin nucleus-managed: shell profile >>>'
  $managedBlockEnd = '# <<< end nucleus-managed: shell profile <<<'
  # Prepended before the direnv hook so the directories are part of the
  # environment direnv saves and restores. No existence guard: a missing dir in
  # PATH is harmless, and the unconditional add means a terminal opened after
  # apply sees the right PATH.
  # Sources: ManagedPaths.ps1 -> managed-paths.nix (pathComponents.append).
  # Each entry (e.g. '.bun\bin') produces a variable definition, a guard, and a
  # PATH assignment.
  $prependLines = $nucleusPathComponents.Prepend | ForEach-Object {
    $__binName = $_ -replace '^\.(.+)\\bin$', '$1'
    $__binVar  = "${__binName}BinDir"
    "`$$__binVar = Join-Path `$env:USERPROFILE `"$_`""
    "if (`$env:PATH -notlike `"*`$$__binVar*`") {"
    "  `$env:PATH = `"`$$__binVar;`$env:PATH`""
    "}"
  }

  $appendLines = $nucleusPathComponents.Append | ForEach-Object {
    $__binName = $_ -replace '^\.(.+)\\bin$', '$1'
    $__binVar  = "${__binName}BinDir"
    "`$$__binVar = Join-Path `$env:USERPROFILE `"$_`""
    "if (`$env:PATH -notlike `"*`$$__binVar*`") {"
    "  `$env:PATH = `"`$env:PATH;`$$__binVar`""
    "}"
  }

  # Managed block content lives in the shared cross-platform profile at
  # src/scripts/shell/profile.ps1.  Read it back here and substitute the three
  # platform-specific tokens so shell-parity content has a single source of
  # truth: the managed PATH prepend/append snippets and the LLVM bin directory.
  # The three -replace substitutions are safe: the snippets carry no `$1`-style
  # group references, which .NET leaves literal, and the prepend/append lines sit
  # between the $managedBlockStart marker on both sides.
  $managedBlock = @($managedBlockStart) + (((Get-Content -Raw (Join-Path $PSScriptRoot -ChildPath '..\..\..\..\scripts\shell\profile.ps1')) -replace '__NUCLEUS_PREPEND_PATH__', ($prependLines -join "`r`n") -replace '__NUCLEUS_APPEND_PATH__', ($appendLines -join "`r`n") -replace '__NUCLEUS_LLVM_BIN_DIR__', (Get-NucleusLLVMBinDir)) -split '\r?\n') + @($managedBlockEnd)

  $profilePaths = @(
    $PROFILE.CurrentUserCurrentHost,
    $PROFILE.CurrentUserAllHosts
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($profilePath in $profilePaths) {
    $profileDirectory = Split-Path -Path $profilePath -Parent
    if ($Enabled -and -not (Test-Path -Path $profileDirectory)) {
      New-Item -ItemType Directory -Path $profileDirectory -Force > $null
    }

    $existingLines = @()
    if (Test-Path -Path $profilePath) {
      $existingLines = @(Get-Content -Path $profilePath)
    }

    $filteredLines = @()
    $insideManagedBlock = $false
    foreach ($line in $existingLines) {
      # WHY: exact sentinel text only -- older sentinel wording is intentionally
      # not stripped (no backwards compatibility; a stale block stays user-owned).
      if ($line -eq $managedBlockStart) {
        $insideManagedBlock = $true
        continue
      }

      if ($line -eq $managedBlockEnd) {
        $insideManagedBlock = $false
        continue
      }

      if (-not $insideManagedBlock) {
        $filteredLines += $line
      }
    }

    if ($Enabled) {
      if ($filteredLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($filteredLines[-1])) {
        $filteredLines += ''
      }

      $filteredLines += $managedBlock
    }

    # WHY: @(...) forces an array so an empty filtered result yields Count 0,
    # not $null.Count (throws under Set-StrictMode when the profile is exactly
    # the managed block and disable strips everything).
    $hasNonWhitespaceLines = @($filteredLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasNonWhitespaceLines) {
      [System.IO.File]::WriteAllLines($profilePath, $filteredLines, [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path -Path $profilePath) {
      Remove-Item -Path $profilePath -Force
    }
  }

  # Method 1 writable symlink, mirroring POSIX pwsh.nix deployment.
  $currentUserHostProfile = $PROFILE.CurrentUserCurrentHost
  if (-not [string]::IsNullOrWhiteSpace($currentUserHostProfile)) {
    $profileDirectory = Split-Path -Path $currentUserHostProfile -Parent
    $settingsPath = Join-Path $profileDirectory 'PSScriptAnalyzerSettings.psd1'
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
      $RepoRoot = $env:NUCLEUS_REPO_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($User)) {
      $User = $env:USERNAME
    }
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild; mirrors pwsh.nix POSIX deployment.
    if ($Enabled) {
      if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'Sync-ShellProfile: NUCLEUS_REPO_ROOT is not set. Run via apply.ps1 which exports this variable.'
      }
      $result = Deploy-UserWritableSymlink -Name 'pwsh-pssa' -User $User -ConfigName 'pwsh' -RelativePath 'PSScriptAnalyzerSettings.psd1' -RepoRoot $RepoRoot -TargetPath $settingsPath
      Write-NucleusInfo -CommandName 'pwsh-pssa' ($result.Message -replace '^pwsh-pssa: ', '')
    }
    elseif (Test-Path -Path $settingsPath -PathType Leaf) {
      Remove-Item -Path $settingsPath -Force
      Write-NucleusInfo -CommandName 'Sync-ShellProfile' "removed $settingsPath"
    }
  }
}
