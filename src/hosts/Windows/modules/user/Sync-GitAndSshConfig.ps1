function Sync-GitAndSshConfig {
  <#
  .SYNOPSIS
    Converges Git + SSH user configuration for all managed Windows users.

  .DESCRIPTION
    Applies a managed Git baseline and an SSH host block for GitHub for every
    user in $Users:
      - system scope: <Git install>\etc\gitconfig symlinked to the repo's
        Windows.gitconfig (commit.gpgsign, tag.gpgsign, core.symlinks,
        core.autocrlf=false plus the installer's shipped defaults; mirrors the
        POSIX /etc/gitconfig symlink), with a same-folder .bak backup of any
        installer-owned original and restore on disable
      - per-user: core.autocrlf=true (Windows override of system false),
        fetch.prune=true, fetch.pruneTags=false, pull.ff=true, pull.rebase=false,
        push.followTags=true, push.autoSetupRemote=true, gpg.format=openpgp,
        init.defaultBranch, init.templateDir, core.excludesFile,
        url.git@github.com:.insteadOf=https://github.com/, user.useConfigOnly
      - user.name / user.email / user.signingkey (from SOPS-managed identity)
      - ~/.ssh/config managed block for Host github.com (per-user key path)
      - ssh-agent service startup set to Automatic (for session persistence)

    When -Enabled:$false is passed, the system-scope symlink is removed (and the
    .bak original restored if present), and managed Git keys and the SSH block
    are removed. Unmanaged settings remain untouched.

  .PARAMETER Enabled
    Whether managed Git/SSH parity should be enforced. False triggers cleanup.

  .PARAMETER Users
    List of usernames for which managed Git/SSH state is applied.

  .EXAMPLE
    Sync-GitAndSshConfig -Enabled:$true -Users @('admin', 'guest')

  .EXAMPLE
    Sync-GitAndSshConfig -Enabled:$false -Users @('admin', 'guest')

  .NOTES
    Environment variables: SystemDrive — used to resolve each user's profile
      directory for per-user Git and SSH configuration.
    Exit codes: 0 on success; non-zero on failure
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true,

    [Parameter(Mandatory = $true)]
    [string[]]$Users
  )

  foreach ($User in $Users) {
    # Resolve the target profile path explicitly from the managed username.
    # check-suppress:suppression_doc: a user-scoped write via the --global flag targets the current process user, so
    # we need deterministic per-user paths to converge each managed profile.
    $userHome = Join-Path -Path $env:SystemDrive -ChildPath "Users\$User"
    if (-not (Test-Path -Path $userHome)) {
      Write-Warning "User profile path for '$User' does not exist: '$userHome'. Skipping."
      continue
    }

    $identityPath = Join-Path -Path $userHome -ChildPath ".config\nucleus\git-identity.env"
    # check-suppress:config-method: method 1 (writable symlink) -- per-user .gitconfig symlinked to the repo's Windows.gitconfig, so git reads managed keys directly from the repo tree (mirrors POSIX git.nix user scope).
    $userGitConfigPath = Join-Path -Path $userHome -ChildPath '.gitconfig'
    $userGitConfigDir = Join-Path -Path $userHome -ChildPath '.config\git'
    # check-suppress:config-method: method 1 (writable symlink) -- per-user ignore file symlinked to the repo's Windows.gitignore (git has no global-scoped ignore; core.excludesFile at user scope is the only mechanism).
    $userIgnorePath = Join-Path -Path $userGitConfigDir -ChildPath 'ignore'
    # Identity include file referenced by [include] path in Windows.gitconfig;
    # writable by this provisioner without touching the symlinked config.
    $identityConfigPath = Join-Path -Path $userGitConfigDir -ChildPath 'identity'
    $identityKv = @{}
    $hasCompleteIdentity = $false
    if (Test-Path -Path $identityPath) {
      $identityLines = Get-Content -Path $identityPath -ErrorAction Stop
      foreach ($line in $identityLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or -not $line.Contains('=')) {
          continue
        }

        $parts = $line -split '=', 2
        $identityKv[$parts[0]] = $parts[1]
      }

      $hasCompleteIdentity =
        ($identityKv.ContainsKey('name') -and -not [string]::IsNullOrWhiteSpace($identityKv['name'])) -and
        ($identityKv.ContainsKey('email') -and -not [string]::IsNullOrWhiteSpace($identityKv['email'])) -and
        ($identityKv.ContainsKey('signingKey') -and -not [string]::IsNullOrWhiteSpace($identityKv['signingKey']))

      if (-not $hasCompleteIdentity) {
        Write-Warning "Git identity payload for user '$User' is incomplete at '$identityPath'; applying managed Git baseline only."
      }
    }
    else {
      Write-Warning "Missing SOPS-managed Git identity payload for user '$User': '$identityPath'. Applying managed Git baseline only."
    }

    $sshDir = Join-Path -Path $userHome -ChildPath '.ssh'
    if ($Enabled -and -not (Test-Path -Path $sshDir)) {
      New-Item -ItemType Directory -Path $sshDir -Force > $null
    }

    $sshConfigPath = Join-Path -Path $sshDir -ChildPath 'config'
    # check-suppress:embedded-content: exception 2 (trivial static content) -- managed ssh config block under 10 lines
    $desiredSshBlock = @(
      'Host github.com'
      '  HostName github.com'
      "  IdentityFile ~/.ssh/ssh_personal_$User"
      '  AddKeysToAgent yes'
    )

    $existingSshLines = @()
    if (Test-Path -Path $sshConfigPath) {
      $existingSshLines = @(Get-Content -Path $sshConfigPath)
    }

    # Find the Host github.com section by parsing SSH config structure.
    # A section starts at a `Host <pattern>` line and spans contiguous lines
    # until the next `Host` directive or EOF. We replace its directives while
    # preserving the Host line itself.
    $githubSectionStart = -1
    $githubSectionEnd = -1
    for ($i = 0; $i -lt $existingSshLines.Count; $i++) {
      $line = $existingSshLines[$i]
      if ($line -match '^Host\s+github\.com(\s|$)') {
        $githubSectionStart = $i
        $githubSectionEnd = $i + 1
        # Scan forward to find the end of this section (next Host or EOF).
        for ($j = $i + 1; $j -lt $existingSshLines.Count; $j++) {
          if ($existingSshLines[$j] -match '^\s*Host\s+') {
            break
          }
          # Skip blank lines before the section end (trailing blank lines belong
          # to the section separator, not the section body).
          if ([string]::IsNullOrWhiteSpace($existingSshLines[$j])) {
            continue
          }
          $githubSectionEnd = $j + 1
        }
        break
      }
    }

    $outputSshLines = @()
    if ($Enabled) {
      if ($githubSectionStart -ge 0) {
        # Replace the found section: keep lines before, inject managed block, skip old body.
        for ($i = 0; $i -lt $githubSectionStart; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
        # Remove trailing blank lines from preceding section for clean output.
        while ($outputSshLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outputSshLines[-1])) {
          $outputSshLines = $outputSshLines[0..($outputSshLines.Count - 2)]
        }
        if ($outputSshLines.Count -gt 0) {
          $outputSshLines += ''
        }
        $outputSshLines += $desiredSshBlock
        # Append all lines after the old section end.
        for ($i = $githubSectionEnd; $i -lt $existingSshLines.Count; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
      }
      else {
        # No existing Host github.com — append managed block at end.
        $outputSshLines = @($existingSshLines)
        # Ensure leading blank line separator.
        if ($outputSshLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($outputSshLines[-1])) {
          $outputSshLines += ''
        }
        $outputSshLines += $desiredSshBlock
      }

      # Validate that all required directives are present in the deployed block.
      $requiredDirectives = @('HostName', 'IdentityFile', 'AddKeysToAgent')
      $deployedText = $outputSshLines -join "`n"
      foreach ($directive in $requiredDirectives) {
        if ($deployedText -notmatch "(?m)^\s+$directive\s+") {
          Write-Warning "Sync-GitAndSshConfig: managed Host github.com block missing required directive '$directive'"
        }
      }
    }
    else {
      # Disabled: remove the managed Host github.com section if present.
      if ($githubSectionStart -ge 0) {
        for ($i = 0; $i -lt $githubSectionStart; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
        for ($i = $githubSectionEnd; $i -lt $existingSshLines.Count; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
        # Clean up any doubled blank lines from the removal.
        $cleaned = @()
        $prevBlank = $false
        foreach ($line in $outputSshLines) {
          $isBlank = [string]::IsNullOrWhiteSpace($line)
          if ($isBlank -and $prevBlank) { continue }
          $cleaned += $line
          $prevBlank = $isBlank
        }
        $outputSshLines = $cleaned
      }
      else {
        $outputSshLines = @($existingSshLines)
      }
    }

    # Write SSH config, removing file if no content remains.
    $hasNonWhitespaceLines = ($outputSshLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasNonWhitespaceLines) {
      [System.IO.File]::WriteAllLines($sshConfigPath, $outputSshLines, [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path -Path $sshConfigPath) {
      Remove-Item -Path $sshConfigPath -Force
    }

    if ($Enabled) {
      # check-suppress:suppression_doc: probe -- git may not be installed; throw handles absence.
      $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
      if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
        throw 'git.exe is required for managed Git parity but was not found in PATH.'
      }

      # User-scope Git config and ignore are method-1 writable symlinks into the
      # repo tree (src/users/default/git/Windows.gitconfig + Windows.gitignore),
      # mirroring POSIX git.nix.  A regular file found at the target is moved to
      # a same-folder .bak before symlinking so disabling can restore it; a
      # pre-existing symlink is simply replaced.
      $gitConfigSource = Join-Path $env:NUCLEUS_REPO_ROOT 'src\users\default\git\Windows.gitconfig'
      if (-not (Test-Path -Path $gitConfigSource -PathType Leaf)) {
        throw "Sync-GitAndSshConfig: Windows.gitconfig source not found at $gitConfigSource"
      }
      if (-not (Test-Path -Path $userGitConfigDir)) {
        New-Item -ItemType Directory -Path $userGitConfigDir -Force > $null
      }
      Save-RegularFileBackup -Path $userGitConfigPath -BackupPath "$userGitConfigPath.bak"
      New-Item -ItemType SymbolicLink -Path $userGitConfigPath -Target $gitConfigSource -Force > $null

      $ignoreSource = Join-Path $env:NUCLEUS_REPO_ROOT 'src\users\default\git\Windows.gitignore'
      if (-not (Test-Path -Path $ignoreSource -PathType Leaf)) {
        throw "Sync-GitAndSshConfig: Windows.gitignore source not found at $ignoreSource"
      }
      Save-RegularFileBackup -Path $userIgnorePath -BackupPath "$userIgnorePath.bak"
      New-Item -ItemType SymbolicLink -Path $userIgnorePath -Target $ignoreSource -Force > $null

      # Create an empty template directory so `init.templateDir` points at an
      # existing (but empty) directory, suppressing the sample hooks and legacy
      # description file that Git otherwise copies into every new .git.
      $emptyTemplateDir = Join-Path -Path $userGitConfigDir -ChildPath 'empty_template'
      if (-not (Test-Path -Path $emptyTemplateDir)) {
        New-Item -ItemType Directory -Path $emptyTemplateDir -Force > $null
      }

      # Remove legacy layering artifacts from pre-symlink deployments: the
      # machine-scoped ProgramData ignore-global and the per-profile ignore-user
      # overlay are superseded by the single symlinked Windows.gitignore.
      foreach ($legacyIgnore in @((Join-Path $env:ProgramData 'nucleus\git\ignore-global'), (Join-Path $userGitConfigDir 'ignore-user'))) {
        if (Test-Path -Path $legacyIgnore) {
          Remove-Item -Path $legacyIgnore -Force
        }
      }

      # Per-user identity lives in the include file referenced by [include] path
      # in Windows.gitconfig; the symlinked .gitconfig is never written.  The
      # include file is also writable when the config itself is read-only.
      if ($hasCompleteIdentity) {
        foreach ($identitySetting in @('user.name', 'user.email', 'user.signingkey')) {
          & $gitExecutable config --file $identityConfigPath $identitySetting $identityKv[$identitySetting.Substring(5)]
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to set Git identity '$identitySetting' for user '$User'."
          }
        }
      }
      else {
        Write-Warning "Applied managed Git baseline for user '$User' without user identity keys."
      }
    }
    else {
      # Disabled: remove the user-scope symlinks and restore any backed-up
      # originals.  A missing .bak simply means the path was managed; nothing to
      # restore.  The identity include file is managed state and is removed.
      foreach ($managedPath in @($userGitConfigPath, $userIgnorePath)) {
        Restore-FileBackup -Path $managedPath -BackupPath "$managedPath.bak"
      }
      if (Test-Path -Path $identityConfigPath) {
        Remove-Item -Path $identityConfigPath -Force
      }
    }
  }

  # Machine-wide Git system scope: symlink <install>\etc\gitconfig to the repo's
  # Windows.gitconfig (commit/tag gpgsign, core symlinks/autocrlf), mirroring the
  # POSIX /etc/gitconfig symlink (src/modules/posix-base.nix). Git for Windows
  # >= 2.24 does not read %ProgramData%\Git\config; <install>\etc\gitconfig is
  # the only system config and is installer-owned, so Windows.gitconfig folds in
  # the installer's shipped defaults (credential.helper, http.sslBackend,
  # core.fscache) and the original file is backed up in the same folder
  # (etc\gitconfig.bak) so disabling restores it.
  # check-suppress:suppression_doc: probe -- git may not be installed; condition handles absence.
  $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if (-not [string]::IsNullOrWhiteSpace($gitExecutable)) {
    $installRoot = Split-Path -Path (Split-Path -Path $gitExecutable -Parent) -Parent
    $systemConfigPath = Join-Path -Path $installRoot -ChildPath 'etc\gitconfig'
    $systemConfigBackup = "$systemConfigPath.bak"
    $managedSource = (Join-Path $env:NUCLEUS_REPO_ROOT 'src\modules\configs\git\Windows.gitconfig').Replace('\', '/')
    # check-suppress:suppression_doc: repo checkout may lack the file; fail loudly instead of silently skipping.
    if (-not (Test-Path -Path $managedSource -PathType Leaf)) {
      throw "Sync-GitAndSshConfig: Windows.gitconfig source not found at $managedSource"
    }
    # check-suppress:config-method: method 1 (writable symlink) -- per-host Windows.gitconfig symlinked into Git's system scope; installer-owned original backed up to etc\gitconfig.bak
    if ($Enabled) {
      Save-RegularFileBackup -Path $systemConfigPath -BackupPath $systemConfigBackup
      New-Item -ItemType SymbolicLink -Path $systemConfigPath -Target $managedSource -Force > $null
    }
    else {
      # WHY: only a managed symlink is removed; a regular file here is unmanaged
      # state (e.g. a newer installer-owned file) and must not be deleted over a
      # stale .bak.
      Restore-FileBackup -Path $systemConfigPath -BackupPath $systemConfigBackup
    }
  }

  if ($Enabled) {
    # check-suppress:suppression_doc: probe whether ssh-agent is installed; Get-Service throws when absent.
    $sshAgentService = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne $sshAgentService) {
      Set-Service -Name 'ssh-agent' -StartupType Automatic
      if ($sshAgentService.Status -ne 'Running') {
        Start-Service -Name 'ssh-agent'
      }
    }
  }
}

# Backup/restore of unmanaged originals displaced by managed symlinks.  Extracted
# from Sync-GitAndSshConfig so the convergence (newest original wins) and
# lossless-restore semantics are unit-testable; see
# tests/hosts/Windows/configuration/git-config-helpers.Tests.ps1.

function Save-RegularFileBackup {
  <#
  .SYNOPSIS
    Moves a regular file at $Path to $BackupPath before a managed symlink replaces it.
  .DESCRIPTION
    When a regular file (installer-owned original, user file, or a newer
    converged copy) occupies $Path, it is moved to $BackupPath so disabling can
    restore it.  A stale backup is overwritten -- the newest original wins
    (convergence).  A symlink at $Path is managed state and is left untouched.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BackupPath
  )
  if (Test-Path -Path $Path -PathType Leaf) {
    $isSymlink = [bool]((Get-Item -Path $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    # check-suppress:suppression_doc: a stale .bak is overwritten so the newest original wins (convergence); a symlink is managed state, nothing to back up.
    if (-not $isSymlink) {
      Move-Item -Path $Path -Destination $BackupPath -Force
    }
  }
}

function Restore-FileBackup {
  <#
  .SYNOPSIS
    Removes a managed symlink at $Path and restores $BackupPath when present.
  .DESCRIPTION
    A symlink at $Path is managed state and is removed.  If $Path is then
    absent and $BackupPath exists, $BackupPath is moved back to $Path (lossless
    restore of the unmanaged original).  A missing backup means no pre-existing
    original; nothing is restored.  A regular file at $Path is unmanaged state
    (e.g. a newer installer-owned file) and is left untouched.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BackupPath
  )
  if (Test-Path -Path $Path) {
    $isSymlink = [bool]((Get-Item -Path $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if ($isSymlink) {
      Remove-Item -Path $Path -Force
    }
  }
  # check-suppress:suppression_doc: missing .bak means no pre-existing original; nothing to restore.
  if (-not (Test-Path -Path $Path) -and (Test-Path -Path $BackupPath)) {
    Move-Item -Path $BackupPath -Destination $Path
  }
}
