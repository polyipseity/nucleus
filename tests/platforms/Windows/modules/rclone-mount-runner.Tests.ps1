<#
.SYNOPSIS
  Pester tests for the cloud-mount runner's required lifecycle inputs (D50).

.DESCRIPTION
  The retry policy (mountAttempts, mountRetryBackoffSeconds, mountAttachTimeoutSeconds) is
  single-sourced from
  cloud-drive.lifecycle in services.json, and the Windows generator injects it as
  NUCLEUS_MOUNT_ATTEMPTS / NUCLEUS_MOUNT_BACKOFF / NUCLEUS_MOUNT_ATTACH_SECONDS.
  The POSIX runner consumes the same three with `:?` — required, no fallback.

  A default in the runner is therefore a SECOND policy definition that can drift
  from the registry, which is what this file pins: a missing value must fail
  loudly and name the variable, and a present value must actually be consumed.

  Every case throws before the runner reaches the health record or the mount
  backend, so these tests perform no mount and write no state. LOCALAPPDATA
  still points at a temp tree, because the health root resolves from it.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/rclone-mount-runner.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../..')
  $script:Runner = Join-Path $repoRoot 'src/scripts/services/rclone-mount.ps1'
  $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("rclone-runner-$([guid]::NewGuid())")
  $null = New-Item -ItemType Directory -Path (Join-Path $script:Root 'la') -Force

  # Inputs every case shares, so the failure under test is the one reported.
  $script:BaseEnv = @{
    NUCLEUS_REPO_ROOT                  = $repoRoot.Path
    LOCALAPPDATA                       = (Join-Path $script:Root 'la')
    NUCLEUS_CLOUD_MOUNT_INSTANCE       = 'local.cloud-mount.iCloud'
    NUCLEUS_RCLONE_REMOTE              = 'iCloud:/'
    NUCLEUS_RCLONE_MOUNT_POINT         = (Join-Path $script:Root 'mnt')
  }
  $script:LifecycleNames = @(
    'NUCLEUS_MOUNT_ATTEMPTS'
    'NUCLEUS_MOUNT_ATTACH_SECONDS'
    'NUCLEUS_MOUNT_BACKOFF'
  )

  # Invoke-Runner — run the real runner in a CHILD process with a controlled
  # environment. A child is required: the runner is a script, not a function
  # module, and the throw must be observed as the process outcome.
  function Invoke-Runner {
    param([hashtable]$Env = @{})

    $saved = @{}
    foreach ($name in $script:LifecycleNames) {
      $saved[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
      foreach ($name in $Env.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$Env[$name]) }
      $output = & pwsh -NoProfile -File $script:Runner 2>&1
      return @{ Output = ($output | Out-String); ExitCode = $LASTEXITCODE }
    } finally {
      foreach ($name in $script:LifecycleNames) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
      }
    }
  }

  function New-CaseEnv {
    # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- Pester helper that merges two hashtables; it mutates no system state and the New- verb reads as "make a case env"
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([hashtable]$Extra = @{})
    $env = @{}
    foreach ($k in $script:BaseEnv.Keys) { $env[$k] = $script:BaseEnv[$k] }
    foreach ($k in $Extra.Keys) { $env[$k] = $Extra[$k] }
    return $env
  }
}

AfterAll {
  Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Ignore
}

Describe 'rclone-mount.ps1 requires the injected lifecycle policy' {

  It 'fails loudly when NUCLEUS_MOUNT_ATTEMPTS is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv)
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_ATTEMPTS not set'
  }

  It 'fails loudly when NUCLEUS_MOUNT_ATTACH_SECONDS is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv @{ NUCLEUS_MOUNT_ATTEMPTS = '1' })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_ATTACH_SECONDS not set'
  }

  It 'fails loudly when NUCLEUS_MOUNT_BACKOFF is unset' {
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = '1'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'NUCLEUS_MOUNT_BACKOFF not set'
  }

  It 'consumes the injected attempts value instead of defaulting it' {
    # A non-numeric value must fail at the conversion: reaching an Int32 cast
    # proves the injected value is what the runner parses, and that no default
    # silently replaced it.
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = 'notanumber'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
        NUCLEUS_MOUNT_BACKOFF         = '1'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'System.Int32'
    $result.Output | Should -Not -Match 'NUCLEUS_MOUNT_ATTEMPTS not set'
  }

  It 'consumes the injected backoff value instead of defaulting it' {
    $result = Invoke-Runner -Env (New-CaseEnv @{
        NUCLEUS_MOUNT_ATTEMPTS        = '1'
        NUCLEUS_MOUNT_ATTACH_SECONDS  = '0'
        NUCLEUS_MOUNT_BACKOFF         = 'notanumber'
      })
    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'System.Int32'
    $result.Output | Should -Not -Match 'NUCLEUS_MOUNT_BACKOFF not set'
  }
}
