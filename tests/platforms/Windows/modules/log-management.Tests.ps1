<#
.SYNOPSIS
  Pester tests for Invoke-LogManagement.ps1 functions.

.DESCRIPTION
  Tests the Invoke-LogManagement.ps1 helpers: the log directory lookups,
  sanitization, expiry, and log directory creation. Rotation belongs to
  nucleus-logs and is covered by scripts/logs.Tests.ps1.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/log-management.Tests.ps1 -Passthru"
#>

BeforeAll {
  # Source the module directly.
  $modulePath = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/Invoke-LogManagement.ps1'
  . $modulePath

  # Capture functions into test scope.
  $Script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-log-tests'

  # The module resolves services.json through the repository root. The Windows CI
  # harness exports it, but a local run does not, so a file that leaves the variable
  # unset makes every case here depend on the shell that happens to launch it.
  $Script:OriginalRepoRoot = $env:NUCLEUS_REPO_ROOT
  $env:NUCLEUS_REPO_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path

  # These cases assert the Windows log tail, so the host key has to resolve to the
  # Windows entry. Without this a machine whose ambient NUCLEUS_HOST names another
  # host resolves that host's directory and the assertion measures the wrong host.
  $Script:OriginalHost = $env:NUCLEUS_HOST
  $env:NUCLEUS_HOST = 'Windows'
}

AfterAll {
  $env:NUCLEUS_REPO_ROOT = $Script:OriginalRepoRoot
  $env:NUCLEUS_HOST = $Script:OriginalHost
  if (Test-Path -LiteralPath $Script:TestDir -PathType Container) {
    Remove-Item -LiteralPath $Script:TestDir -Recurse -Force
  }
}

Describe 'Get-NucleusLogDir' {
  It 'returns a non-empty string' {
    $result = Get-NucleusLogDir
    $result | Should -Not -BeNullOrEmpty
  }

  It 'returns path ending with nucleus\log' {
    $result = Get-NucleusLogDir
    $result | Should -Match 'nucleus[\\/]log$'
  }
}

Describe 'Get-NucleusSystemLogDir' {
  It 'returns a non-empty string' {
    $result = Get-NucleusSystemLogDir
    $result | Should -Not -BeNullOrEmpty
  }

  It 'returns path ending with nucleus\log' {
    $result = Get-NucleusSystemLogDir
    $result | Should -Match 'nucleus[\\/]log$'
  }
}

Describe 'ConvertTo-SanitizedText' {
  It 'strips ANSI escape sequences' {
    $inputText = "`e[31mred`e[0m normal"
    $result = $inputText | ConvertTo-SanitizedText
    $result | Should -Be "red normal"
  }

  It 'strips carriage returns' {
    $inputText = "line1`r`nline2"
    $result = $inputText | ConvertTo-SanitizedText
    $result | Should -Be "line1`nline2"
  }
}

Describe 'Invoke-LogExpiry' {
  BeforeEach {
    $dir = Join-Path $Script:TestDir ([System.IO.Path]::GetRandomFileName())
    New-Item -Path $dir -ItemType Directory -Force > $null
    $Script:ExpiryDir = $dir
  }

  AfterEach {
    if (Test-Path -LiteralPath $Script:ExpiryDir -PathType Container) {
      Remove-Item -LiteralPath $Script:ExpiryDir -Recurse -Force
    }
  }

  It 'deletes old rotated archives but keeps active logs' {
    $active = Join-Path $Script:ExpiryDir 'combined.log'
    $archive = Join-Path $Script:ExpiryDir 'combined.1.log'
    Set-Content -Path $active -Value 'active'
    Set-Content -Path $archive -Value 'old'
    (Get-Item -LiteralPath $archive).LastWriteTime = (Get-Date).AddDays(-30)

    Invoke-LogExpiry -Path $Script:ExpiryDir -Expiry '7d'

    (Test-Path -LiteralPath $active -PathType Leaf) | Should -Be $true
    (Test-Path -LiteralPath $archive -PathType Leaf) | Should -Be $false
  }
}

Describe 'Invoke-EnsureLogDir' {
  BeforeAll {
    # Source the function.
    $ensureLogDirPath = Join-Path $PSScriptRoot '../../../../src/platforms/Windows/modules/system/Invoke-EnsureLogDir.ps1'
    . $ensureLogDirPath

    $Script:TestServicesJson = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-test-services.json'
    $Script:TestSystemLogDir = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-test-system-log'
    $Script:TestUserLogDir = Join-Path ([System.IO.Path]::GetTempPath()) 'nucleus-test-user-log'
  }

  AfterAll {
    foreach ($p in @($Script:TestServicesJson, $Script:TestSystemLogDir, $Script:TestUserLogDir)) {
      if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Recurse -Force
      }
    }
  }

  It 'creates system subdirectories from services.json' {
    # Stub services.json with one system dir entry.
    $stub = @'
{
  "test-svc": {
    "hosts": {
      "Windows": { "platform": "Windows", "type": "service" }
    },
    "logging": {
      "dirs": { "system": ["test-svc"], "user": [] }
    }
  }
}
'@
    Set-Content -Path $Script:TestServicesJson -Value $stub -Encoding utf8

    # Mock log dir functions by overriding with test vars.
    Mock Get-NucleusSystemLogDir { return $Script:TestSystemLogDir }
    Mock Get-NucleusLogDir { return $Script:TestUserLogDir }

    Invoke-EnsureLogDir -ServicesJson $Script:TestServicesJson

    $expectedDir = Join-Path $Script:TestSystemLogDir 'test-svc'
    (Test-Path -LiteralPath $expectedDir -PathType Container) | Should -Be $true
  }

  It 'creates user subdirectories from services.json' {
    $stub = @'
{
  "test-user-svc": {
    "hosts": {
      "Windows": { "platform": "Windows", "type": "service" }
    },
    "logging": {
      "dirs": { "system": [], "user": ["test-user-svc"] }
    }
  }
}
'@
    Set-Content -Path $Script:TestServicesJson -Value $stub -Encoding utf8

    Mock Get-NucleusSystemLogDir { return $Script:TestSystemLogDir }
    Mock Get-NucleusLogDir { return $Script:TestUserLogDir }

    Invoke-EnsureLogDir -ServicesJson $Script:TestServicesJson

    $expectedDir = Join-Path $Script:TestUserLogDir 'test-user-svc'
    (Test-Path -LiteralPath $expectedDir -PathType Container) | Should -Be $true
  }

  It 'handles services with no logging.dirs' {
    $stub = @'
{
  "no-log-svc": {
    "hosts": {
      "Windows": { "platform": "Windows", "type": "service" }
    }
  }
}
'@
    Set-Content -Path $Script:TestServicesJson -Value $stub -Encoding utf8

    Mock Get-NucleusSystemLogDir { return $Script:TestSystemLogDir }
    Mock Get-NucleusLogDir { return $Script:TestUserLogDir }

    # Should not throw.
    { Invoke-EnsureLogDir -ServicesJson $Script:TestServicesJson } | Should -Not -Throw
  }
}
