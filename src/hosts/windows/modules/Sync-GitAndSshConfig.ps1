# modules/windows/git-ssh.ps1 — Git and SSH parity helpers for Windows.
#
# Keeps user-level Git identity/signing and SSH host rules aligned with the
# POSIX baseline while preserving cleanup behavior when disabled.

function Sync-GitAndSshConfig {
  <#
  .SYNOPSIS
    Converges Git + SSH user configuration for all managed Windows users.

  .DESCRIPTION
    Applies a managed Git baseline and an SSH host block for GitHub for every
    user in $Users:
      - commit.gpgsign=true
      - tag.gpgsign=true
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
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true,

    [Parameter(Mandatory = $true)]
    [string[]]$Users
  )

  foreach ($User in $Users) {
    # Resolve the target profile path explicitly from the managed username.
    # WHY: `git config --global` always targets the current process user, so
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
      New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $sshConfigPath = Join-Path -Path $sshDir -ChildPath 'config'
    $managedBlockStart = "# >>> config managed github ssh [$User] >>>"
    $managedBlockEnd = "# <<< config managed github ssh [$User] <<<"
    $managedSshBlock = @(
      $managedBlockStart
      'Host github.com'
      '  HostName github.com'
      "  IdentityFile ~/.ssh/ssh_personal_$User"
      '  AddKeysToAgent yes'
      $managedBlockEnd
    )

    $existingSshLines = @()
    if (Test-Path -Path $sshConfigPath) {
      $existingSshLines = @(Get-Content -Path $sshConfigPath)
    }

    $outputSshLines = @()
    $insideManagedBlock = $false
    foreach ($line in $existingSshLines) {
      if ($line -eq $managedBlockStart) {
        $insideManagedBlock = $true
        continue
      }

      if ($line -eq $managedBlockEnd) {
        $insideManagedBlock = $false
        continue
      }

      if (-not $insideManagedBlock) {
        $outputSshLines += $line
      }
    }

    if ($Enabled) {
      if ($outputSshLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($outputSshLines[-1])) {
        $outputSshLines += ''
      }

      $outputSshLines += $managedSshBlock
    }

    $hasNonWhitespaceLines = ($outputSshLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasNonWhitespaceLines) {
      [System.IO.File]::WriteAllLines($sshConfigPath, $outputSshLines, [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path -Path $sshConfigPath) {
      Remove-Item -Path $sshConfigPath -Force
    }

    if ($Enabled) {
      $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
      if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
        throw 'git.exe is required for managed Git parity but was not found in PATH.'
      }

      $managedGitSettings = [ordered]@{
        'commit.gpgsign' = 'true'
        'core.autocrlf' = 'true'
        'core.symlinks' = 'true'
        'gpg.format' = 'openpgp'
        'init.defaultBranch' = 'main'
        'tag.gpgsign' = 'true'
        'url.git@github.com:.insteadOf' = 'https://github.com/'
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
      $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
      if (-not [string]::IsNullOrWhiteSpace($gitExecutable)) {
        $managedGitSettings = [ordered]@{
          'commit.gpgsign' = 'true'
          'core.autocrlf' = 'true'
          'core.symlinks' = 'true'
          'gpg.format' = 'openpgp'
          'init.defaultBranch' = 'main'
          'tag.gpgsign' = 'true'
          'url.git@github.com:.insteadOf' = 'https://github.com/'
          'user.email' = $null
          'user.name' = $null
          'user.signingkey' = $null
        }

        foreach ($settingKey in $managedGitSettings.Keys) {
          & $gitExecutable config --file $gitConfigPath --unset-all $settingKey *> $null
        }
      }
    }
  }

  if ($Enabled) {
    $sshAgentService = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne $sshAgentService) {
      Set-Service -Name 'ssh-agent' -StartupType Automatic
      if ($sshAgentService.Status -ne 'Running') {
        Start-Service -Name 'ssh-agent'
      }
    }
  }
}
