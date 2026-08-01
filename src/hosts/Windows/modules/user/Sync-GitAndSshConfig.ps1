function Sync-GitAndSshConfig {
  <#
  .SYNOPSIS
    Converges Git + SSH user configuration for all managed Windows users.

  .DESCRIPTION
    Applies a managed Git baseline and an SSH host block for GitHub for every
    user in $Users:
      - commit.gpgsign=true
      - tag.gpgsign=true
      - fetch.prune=true
      - fetch.pruneTags=false
      - pull.ff=true
      - pull.rebase=false
      - push.followTags=true
      - gpg.format=openpgp
      - user.name / user.email / user.signingkey (from SOPS-managed identity)
      - url.git@github.com:.insteadOf=https://github.com/
      - ~/.ssh/config managed block for Host github.com (per-user key path)
      - ssh-agent service startup set to Automatic (for session persistence)

    When -Enabled:$false is passed, only the managed Git keys and SSH block are
    removed. Unmanaged settings remain untouched.

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
    # check-suppress:suppression_doc: `git config --global` always targets the current process user, so
    # we need deterministic per-user paths to converge each managed profile.
    $userHome = Join-Path -Path $env:SystemDrive -ChildPath "Users\$User"
    if (-not (Test-Path -Path $userHome)) {
      Write-Warning "User profile path for '$User' does not exist: '$userHome'. Skipping."
      continue
    }

    $gitConfigPath = Join-Path -Path $userHome -ChildPath '.gitconfig'
    $identityPath = Join-Path -Path $userHome -ChildPath ".config\nucleus\git-identity.env"
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

      # Global + user-specific gitignore layering:
      # - global baseline in ProgramData (machine scope, shared by all users)
      # - user overlay in each profile
      # - merged effective file consumed by core.excludesFile
      $globalIgnoreDir = Join-Path -Path $env:ProgramData -ChildPath 'nucleus\git'
      $globalIgnorePath = Join-Path -Path $globalIgnoreDir -ChildPath 'ignore-global'
      $userGitConfigDir = Join-Path -Path $userHome -ChildPath '.config\git'
      $userIgnorePath = Join-Path -Path $userGitConfigDir -ChildPath 'ignore-user'
      $effectiveIgnorePath = Join-Path -Path $userGitConfigDir -ChildPath 'ignore'

      if (-not (Test-Path -Path $globalIgnoreDir)) {
        New-Item -ItemType Directory -Path $globalIgnoreDir -Force > $null
      }
      if (-not (Test-Path -Path $userGitConfigDir)) {
        New-Item -ItemType Directory -Path $userGitConfigDir -Force > $null
      }

      # Create an empty template directory so `init.templateDir` points at an
      # existing (but empty) directory, suppressing the sample hooks and legacy
      # description file that Git otherwise copies into every new .git.
      $emptyTemplateDir = Join-Path -Path $userGitConfigDir -ChildPath 'empty_template'
      if (-not (Test-Path -Path $emptyTemplateDir)) {
        New-Item -ItemType Directory -Path $emptyTemplateDir -Force > $null
      }

      # check-suppress:config-method: method 1 (writable symlink) -- global gitignore symlinked to repo file.
      # Mirrors the POSIX git.nix deployment of system.gitignore.
      $globalIgnoreSource = Join-Path $env:NUCLEUS_REPO_ROOT 'src\modules\configs\git\system.gitignore'
      if (-not (Test-Path -Path $globalIgnoreSource -PathType Leaf)) {
        throw "Sync-GitAndSshConfig: system.gitignore source not found at $globalIgnoreSource"
      }
      if (Test-Path -Path $globalIgnorePath) {
        Remove-Item -Path $globalIgnorePath -Force
      }
      New-Item -Path $globalIgnorePath -ItemType SymbolicLink -Target $globalIgnoreSource -Force > $null

      if (-not (Test-Path -Path $userIgnorePath)) {
        $userIgnoreTemplate = @(
          '# User-specific Git ignore patterns.'
          '# Add one pattern per line; these are appended after ignore-global.'
        )
        [System.IO.File]::WriteAllLines($userIgnorePath, $userIgnoreTemplate, [System.Text.UTF8Encoding]::new($false))
      }

      $effectiveIgnoreLines = @()
      $effectiveIgnoreLines += Get-Content -Path $globalIgnorePath -ErrorAction Stop
      $effectiveIgnoreLines += ''
      $effectiveIgnoreLines += Get-Content -Path $userIgnorePath -ErrorAction Stop
      [System.IO.File]::WriteAllLines($effectiveIgnorePath, $effectiveIgnoreLines, [System.Text.UTF8Encoding]::new($false))

      $managedGitSettings = [ordered]@{
        'commit.gpgsign' = 'true'
        'core.autocrlf' = 'true'
        'core.excludesFile' = $effectiveIgnorePath
        'core.symlinks' = 'true'
        'fetch.prune' = 'true'
        'fetch.pruneTags' = 'false'
        'gpg.format' = 'openpgp'
        'init.defaultBranch' = 'main'
        'init.templateDir' = '~/.config/git/empty_template'
        'pull.ff' = 'true'
        'pull.rebase' = 'false'
        'push.autoSetupRemote' = 'true'
        'push.followTags' = 'true'
        'tag.gpgsign' = 'true'
        'url.git@github.com:.insteadOf' = 'https://github.com/'
        'user.useConfigOnly' = 'true'
      }

      if ($hasCompleteIdentity) {
        $managedGitSettings['user.email'] = $identityKv['email']
        $managedGitSettings['user.name'] = $identityKv['name']
        $managedGitSettings['user.signingkey'] = $identityKv['signingKey']
      }

      foreach ($settingKey in $managedGitSettings.Keys) {
        & $gitExecutable config --file $gitConfigPath $settingKey $managedGitSettings[$settingKey]
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to set Git config '$settingKey' for user '$User'."
        }
      }

      if (-not $hasCompleteIdentity) {
        Write-Warning "Applied managed Git signing defaults for user '$User' without user identity keys."
      }
    }
    else {
      # check-suppress:suppression_doc: probe -- git may not be installed; condition handles absence.
      $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
      if (-not [string]::IsNullOrWhiteSpace($gitExecutable)) {
        $managedGitSettings = [ordered]@{
          'commit.gpgsign' = 'true'
          'core.autocrlf' = 'true'
          'core.excludesFile' = $null
          'core.symlinks' = 'true'
          'fetch.prune' = 'true'
          'fetch.pruneTags' = 'false'
          'gpg.format' = 'openpgp'
          'init.defaultBranch' = 'main'
          'pull.ff' = $null
          'pull.rebase' = $null
          'push.autoSetupRemote' = $null
          'push.followTags' = 'true'
          'tag.gpgsign' = 'true'
          'url.git@github.com:.insteadOf' = 'https://github.com/'
          'user.email' = $null
          'user.name' = $null
          'user.signingkey' = $null
          'user.useConfigOnly' = $null
        }

        foreach ($settingKey in $managedGitSettings.Keys) {
          & $gitExecutable config --file $gitConfigPath --unset-all $settingKey *> $null
        }
      }
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
