function Sync-GitAndSshConfig {
  <#
  .SYNOPSIS
    Converges Git + SSH user configuration for all managed Windows users.

  .DESCRIPTION
    Applies a managed Git baseline and an SSH host block for GitHub per user in
    $Users: a system-scope <Git install>\etc\gitconfig symlinked to the repo's
    <Host>.gitconfig (mirroring the POSIX /etc/gitconfig symlink), a per-user
    .gitconfig and ignore symlinked the same way, identity in the [include] file,
    and ~/.ssh/config managed for Host github.com.

    -Enabled:$false removes the managed symlinks and restores a .bak original
    when one exists. Unmanaged settings stay untouched.

  .PARAMETER Enabled
    False triggers cleanup instead of convergence.

  .NOTES
    Environment variables: SystemDrive resolves each user profile directory;
    NUCLEUS_HOST selects the per-host config files.
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true,

    [Parameter(Mandatory = $true)]
    [string[]]$Users
  )

  # WHY no fallback: a missing NUCLEUS_HOST would silently target the wrong repo file.
  $hostName = $env:NUCLEUS_HOST
  if ([string]::IsNullOrWhiteSpace($hostName)) {
    throw 'Sync-GitAndSshConfig: NUCLEUS_HOST must be set (apply.ps1 sets it to the canonical hostname).'
  }

  foreach ($User in $Users) {
    # check-suppress:suppression_doc: a user-scoped write via the --global flag targets the current process user, so
    # we need deterministic per-user paths to converge each managed profile.
    $userHome = Join-Path -Path $env:SystemDrive -ChildPath "Users\$User"
    if (-not (Test-Path -Path $userHome)) {
      Write-NucleusWarning -CommandName 'Sync-GitAndSshConfig' "User profile path for '$User' does not exist: '$userHome'. Skipping."
      continue
    }

    $identityPath = Join-Path -Path $userHome -ChildPath "AppData\Local\nucleus\git-identity.env"
    # check-suppress:config-method: method 1 (writable symlink) -- per-user .gitconfig symlinked to the repo's <Host>.gitconfig (derived from $env:NUCLEUS_HOST; mirrors POSIX git.nix user scope), so git reads managed keys directly from the repo tree.
    $userGitConfigPath = Join-Path -Path $userHome -ChildPath '.gitconfig'
    $userGitConfigDir = Join-Path -Path $userHome -ChildPath '.config\git'
    # check-suppress:config-method: method 1 (writable symlink) -- per-user ignore file symlinked to the repo's <Host>.gitignore (git has no global-scoped ignore; core.excludesFile at user scope is the only mechanism).
    $userIgnorePath = Join-Path -Path $userGitConfigDir -ChildPath 'ignore'
    # Identity include file referenced by [include] path in <Host>.gitconfig.
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
        Write-NucleusWarning -CommandName 'Sync-GitAndSshConfig' "Git identity payload for user '$User' is incomplete at '$identityPath'; applying managed Git baseline only."
      }
    }
    else {
      Write-NucleusWarning -CommandName 'Sync-GitAndSshConfig' "Missing SOPS-managed Git identity payload for user '$User': '$identityPath'. Applying managed Git baseline only."
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

    # WHY parse the section: a section spans from its `Host` line to the next
    # `Host` directive or EOF, and blank lines belong to the separator, not the
    # body.
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
          # Blank lines before the section end belong to the separator.
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
        # Replace the section: keep the lines before it, inject the managed block, drop the old body.
        for ($i = 0; $i -lt $githubSectionStart; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
        while ($outputSshLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outputSshLines[-1])) {
          $outputSshLines = $outputSshLines[0..($outputSshLines.Count - 2)]
        }
        if ($outputSshLines.Count -gt 0) {
          $outputSshLines += ''
        }
        $outputSshLines += $desiredSshBlock
        for ($i = $githubSectionEnd; $i -lt $existingSshLines.Count; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
      }
      else {
        $outputSshLines = @($existingSshLines)
        if ($outputSshLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($outputSshLines[-1])) {
          $outputSshLines += ''
        }
        $outputSshLines += $desiredSshBlock
      }

      $requiredDirectives = @('HostName', 'IdentityFile', 'AddKeysToAgent')
      $deployedText = $outputSshLines -join "`n"
      foreach ($directive in $requiredDirectives) {
        if ($deployedText -notmatch "(?m)^\s+$directive\s+") {
          Write-NucleusWarning -CommandName 'Sync-GitAndSshConfig' "managed Host github.com block missing required directive '$directive'"
        }
      }
    }
    else {
      if ($githubSectionStart -ge 0) {
        for ($i = 0; $i -lt $githubSectionStart; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
        for ($i = $githubSectionEnd; $i -lt $existingSshLines.Count; $i++) {
          $outputSshLines += $existingSshLines[$i]
        }
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
      # per-user overlay (src/users/<User>/git/<Host>.gitconfig + <Host>.gitignore
      # with src/users/default fallback), mirroring POSIX users-overlay.nix; the
      # helper fails fast when neither exists.  A regular file found at the target
      # is moved to a same-folder .bak before symlinking so disabling can restore
      # it; a pre-existing symlink is simply replaced.
      $gitConfigSource = Resolve-UserConfigSource -User $User -ConfigName 'git' -Extension 'gitconfig' -HostName $hostName -RepoRoot $env:NUCLEUS_REPO_ROOT
      if (-not (Test-Path -Path $userGitConfigDir)) {
        New-Item -ItemType Directory -Path $userGitConfigDir -Force > $null
      }
      Save-RegularFileBackup -Path $userGitConfigPath -BackupPath "$userGitConfigPath.bak"
      New-Item -ItemType SymbolicLink -Path $userGitConfigPath -Target $gitConfigSource -Force > $null

      $ignoreSource = Resolve-UserConfigSource -User $User -ConfigName 'git' -Extension 'gitignore' -HostName $hostName -RepoRoot $env:NUCLEUS_REPO_ROOT
      Save-RegularFileBackup -Path $userIgnorePath -BackupPath "$userIgnorePath.bak"
      New-Item -ItemType SymbolicLink -Path $userIgnorePath -Target $ignoreSource -Force > $null

      # WHY the empty template dir: init.templateDir pointing at an existing empty
      # directory suppresses the sample hooks Git otherwise copies into every
      # new .git.
      $emptyTemplateDir = Join-Path -Path $userGitConfigDir -ChildPath 'empty_template'
      if (-not (Test-Path -Path $emptyTemplateDir)) {
        New-Item -ItemType Directory -Path $emptyTemplateDir -Force > $null
      }

      # WHY the include file: the symlinked .gitconfig is never written, so identity
      # keys go to the file [include] names.
      if ($hasCompleteIdentity) {
        foreach ($identitySetting in @('user.name', 'user.email', 'user.signingkey')) {
          & $gitExecutable config --file $identityConfigPath $identitySetting $identityKv[$identitySetting.Substring(5)]
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to set Git identity '$identitySetting' for user '$User'."
          }
        }
      }
      else {
        Write-NucleusWarning -CommandName 'Sync-GitAndSshConfig' "Applied managed Git baseline for user '$User' without user identity keys."
      }
    }
    else {
      # Disabled: remove the user-scope symlinks and restore any backed-up originals.
      # A missing .bak means the path was managed, nothing to restore.
      foreach ($managedPath in @($userGitConfigPath, $userIgnorePath)) {
        Restore-FileBackup -Path $managedPath -BackupPath "$managedPath.bak"
      }
      if (Test-Path -Path $identityConfigPath) {
        Remove-Item -Path $identityConfigPath -Force
      }
    }
  }

  # Machine-wide Git system scope: symlink <install>\etc\gitconfig to the repo's
  # <Host>.gitconfig (installer shipped defaults only — signing, newline and
  # symlink defaults are user-scoped), mirroring the POSIX /etc/gitconfig
  # symlink (src/modules/posix/base.nix). Git for Windows
  # >= 2.24 does not read %ProgramData%\Git\config; <install>\etc\gitconfig is
  # the only system config and is installer-owned, so <Host>.gitconfig folds in
  # the installer's shipped defaults (credential.helper, http.sslBackend,
  # core.fscache) and the original file is backed up in the same folder
  # (etc\gitconfig.bak) so disabling restores it.
  # check-suppress:suppression_doc: probe -- git may not be installed; condition handles absence.
  $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if (-not [string]::IsNullOrWhiteSpace($gitExecutable)) {
    $installRoot = Split-Path -Path (Split-Path -Path $gitExecutable -Parent) -Parent
    $systemConfigPath = Join-Path -Path $installRoot -ChildPath 'etc\gitconfig'
    $systemConfigBackup = "$systemConfigPath.bak"
    # check-suppress:config-method: method 1 (writable symlink) -- per-host <Host>.gitconfig symlinked into Git's system scope; installer-owned original backed up to etc\gitconfig.bak
    $managedSource = (Join-Path $env:NUCLEUS_REPO_ROOT "src\modules\configs\git\$hostName.gitconfig").Replace('\', '/')
    # check-suppress:suppression_doc: repo checkout may lack the file; fail loudly instead of silently skipping.
    if (-not (Test-Path -Path $managedSource -PathType Leaf)) {
      throw "Sync-GitAndSshConfig: $hostName.gitconfig source not found at $managedSource"
    }
    if ($Enabled) {
      Save-RegularFileBackup -Path $systemConfigPath -BackupPath $systemConfigBackup
      New-Item -ItemType SymbolicLink -Path $systemConfigPath -Target $managedSource -Force > $null
    }
    else {
      # WHY restore rather than delete: only a managed symlink is removed, and a
      # regular file here is unmanaged state (e.g. a newer installer-owned file).
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

# WHY extracted: backup-once and lossless restore are unit-tested separately,
# see tests/hosts/Windows/configuration/git-config-helpers.Tests.ps1.

function Save-RegularFileBackup {
  <#
  .SYNOPSIS
    Moves a regular file at $Path to $BackupPath before a managed symlink replaces it.
  .DESCRIPTION
    Backup-once: the first original wins, a stale .bak is never overwritten, and
    the current file stays for the symlink to replace, matching POSIX `ln -sf`.
    A symlink at $Path is managed state and is left untouched.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BackupPath
  )
  if (Test-Path -Path $Path -PathType Leaf) {
    $isSymlink = [bool]((Get-Item -Path $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    # check-suppress:suppression_doc: backup-once mirrors POSIX -- a stale .bak is preserved (first original wins) and the current file stays for the symlink to replace (ln -sf parity); a symlink is managed state, nothing to back up.
    if (-not $isSymlink -and -not (Test-Path -Path $BackupPath)) {
      Move-Item -Path $Path -Destination $BackupPath
    }
  }
}

function Restore-FileBackup {
  <#
  .SYNOPSIS
    Removes a managed symlink at $Path and restores $BackupPath when present.
  .DESCRIPTION
    A managed symlink at $Path is removed, then $BackupPath moves back when it
    exists (lossless restore of the unmanaged original). A missing backup means
    no pre-existing original; a regular file at $Path is unmanaged state.
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
