# modules/windows/git-ssh.ps1 — Git and SSH parity helpers for Windows.
#
# Keeps user-level Git identity/signing and SSH host rules aligned with the
# POSIX baseline while preserving cleanup behavior when disabled.

function Sync-NucleusGitAndSshConfig {
  <#
  .SYNOPSIS
    Converges Git + SSH user configuration for the primary Windows user.

  .DESCRIPTION
    Applies a managed Git baseline and an SSH host block for GitHub:
      - commit.gpgsign=true
      - tag.gpgsign=true
      - gpg.format=openpgp
      - user.name / user.email / user.signingkey (from per-user mapping)
      - url.git@github.com:.insteadOf=https://github.com/
      - ~/.ssh/config managed block for Host github.com

    When -Enabled:$false is passed, only the managed Git keys and SSH block are
    removed. Unmanaged settings remain untouched.

  .PARAMETER Enabled
    Whether managed Git/SSH parity should be enforced. False triggers cleanup.

  .PARAMETER PrimaryUsername
    Canonical primary username allowed to receive managed Git/SSH state.

  .EXAMPLE
    Sync-NucleusGitAndSshConfig -Enabled:$true -PrimaryUsername 'polyipseity'

  .EXAMPLE
    Sync-NucleusGitAndSshConfig -Enabled:$false -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername
  )

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  $gitIdentityByUsername = @{
    polyipseity = @{
      Email = 'polyipseity@gmail.com'
      Name = 'William So'
      SigningKey = '307DBE2F09912754!'
    }
  }

  if (-not $gitIdentityByUsername.ContainsKey($PrimaryUsername)) {
    throw "No Git identity mapping defined for primary user '$PrimaryUsername'."
  }

  $selectedIdentity = $gitIdentityByUsername[$PrimaryUsername]
  if ([string]::IsNullOrWhiteSpace($selectedIdentity.SigningKey)) {
    throw "Mapped user '$PrimaryUsername' must define a non-empty Git signing key."
  }

  $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
    throw 'git.exe is required for managed Git parity but was not found in PATH.'
  }

  $managedGitSettings = [ordered]@{
    'commit.gpgsign' = 'true'
    'core.autocrlf' = 'auto'
    'core.symlinks' = 'true'
    'gpg.format' = 'openpgp'
    'tag.gpgsign' = 'true'
    'url.git@github.com:.insteadOf' = 'https://github.com/'
    'user.email' = $selectedIdentity.Email
    'user.name' = $selectedIdentity.Name
    'user.signingkey' = $selectedIdentity.SigningKey
  }

  if ($Enabled) {
    foreach ($settingKey in $managedGitSettings.Keys) {
      & $gitExecutable config --global $settingKey $managedGitSettings[$settingKey]
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Git config '$settingKey'."
      }
    }
  }
  else {
    foreach ($settingKey in $managedGitSettings.Keys) {
      & $gitExecutable config --global --unset-all $settingKey *> $null
    }
  }

  $sshDir = Join-Path -Path $HOME -ChildPath '.ssh'
  if ($Enabled -and -not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }

  $sshConfigPath = Join-Path -Path $sshDir -ChildPath 'config'
  $managedBlockStart = '# >>> nucleus managed github ssh >>>'
  $managedBlockEnd = '# <<< nucleus managed github ssh <<<'
  $managedSshBlock = @(
    $managedBlockStart
    'Host github.com'
    '  HostName github.com'
    "  IdentityFile ~/.ssh/ssh_personal_$PrimaryUsername"
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
    Remove-Item -Path $sshConfigPath -Force -ErrorAction SilentlyContinue
  }
}
