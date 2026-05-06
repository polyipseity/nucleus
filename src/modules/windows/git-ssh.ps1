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
      - user.name / user.email / user.signingkey (from SOPS-managed identity)
      - url.git@github.com:.insteadOf=https://github.com/
      - ~/.ssh/config managed block for Host github.com
      - ssh-agent service startup set to Automatic (for session persistence)

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

  $identityPath = Join-Path -Path $HOME -ChildPath ".config\nucleus\git-identity.env"
  if (-not (Test-Path -Path $identityPath)) {
    throw "Missing SOPS-managed Git identity payload: '$identityPath'."
  }

  $identityLines = Get-Content -Path $identityPath -ErrorAction Stop
  $identityKv = @{}
  foreach ($line in $identityLines) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or -not $line.Contains('=')) {
      continue
    }

    $parts = $line -split '=', 2
    $identityKv[$parts[0]] = $parts[1]
  }

  if (-not $identityKv.ContainsKey('name') -or [string]::IsNullOrWhiteSpace($identityKv['name'])) {
    throw "Git identity payload '$identityPath' is missing non-empty 'name='."
  }

  if (-not $identityKv.ContainsKey('email') -or [string]::IsNullOrWhiteSpace($identityKv['email'])) {
    throw "Git identity payload '$identityPath' is missing non-empty 'email='."
  }

  if (-not $identityKv.ContainsKey('signingKey') -or [string]::IsNullOrWhiteSpace($identityKv['signingKey'])) {
    throw "Git identity payload '$identityPath' is missing non-empty 'signingKey='."
  }

  $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
    throw 'git.exe is required for managed Git parity but was not found in PATH.'
  }

  $managedGitSettings = [ordered]@{
    'commit.gpgsign' = 'true'
    'core.autocrlf' = 'true'
    'core.symlinks' = 'true'
    'gpg.format' = 'openpgp'
    'tag.gpgsign' = 'true'
    'url.git@github.com:.insteadOf' = 'https://github.com/'
    'user.email' = $identityKv['email']
    'user.name' = $identityKv['name']
    'user.signingkey' = $identityKv['signingKey']
  }

  if ($Enabled) {
    # Ensure ssh-agent survives logoff/reboot so AddKeysToAgent can persist key
    # loading behavior across sessions without manual service management.
    $sshAgentService = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne $sshAgentService) {
      Set-Service -Name 'ssh-agent' -StartupType Automatic
      if ($sshAgentService.Status -ne 'Running') {
        Start-Service -Name 'ssh-agent'
      }
    }

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
