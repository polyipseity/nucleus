<#
.SYNOPSIS
  Pester tests for Invoke-LogManagement.ps1 functions.

.DESCRIPTION
  Tests Invoke-LogRotation, Get-NucleusLogDir, Get-NucleusSystemLogDir,
  and ConvertTo-SanitizedText from the Invoke-LogManagement module.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/log-management.Tests.ps1 -Passthru"
#>

BeforeAll {
  # Source the module directly.
  $modulePath = Join-Path $PSScriptRoot '../../../src/hosts/Windows/modules/Invoke-LogManagement.ps1'
  . $modulePath

  # Capture functions into test scope.
  $Script:TestDir = "$(Join-Path $env:TEMP 'nucleus-log-tests')"
}

AfterAll {
  if (Test-Path -LiteralPath $Script:TestDir -PathType Container) {
    Remove-Item -LiteralPath $Script:TestDir -Recurse -Force
  }
}

Describe 'Get-NucleusLogDir' {
  It 'returns a non-empty string' {
    $result = Get-NucleusLogDir
    $result | Should -Not -BeNullOrEmpty
  }

  It 'returns path ending with nucleus\logs' {
    $result = Get-NucleusLogDir
    $result | Should -Match 'nucleus[\\/]logs$'
  }
}

Describe 'Get-NucleusSystemLogDir' {
  It 'returns a non-empty string' {
    $result = Get-NucleusSystemLogDir
    $result | Should -Not -BeNullOrEmpty
  }

  It 'returns path ending with nucleus\logs' {
    $result = Get-NucleusSystemLogDir
    $result | Should -Match 'nucleus[\\/]logs$'
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

Describe 'Invoke-LogRotation' {
  BeforeEach {
    # Create a fresh test directory per test.
    $dir = Join-Path $Script:TestDir ([System.IO.Path]::GetRandomFileName())
    New-Item -Path $dir -ItemType Directory -Force > $null
    $Script:LogDir = $dir
  }

  AfterEach {
    if (Test-Path -LiteralPath $Script:LogDir -PathType Container) {
      Remove-Item -LiteralPath $Script:LogDir -Recurse -Force
    }
  }

  It 'is a no-op on missing directory' {
    # Should not throw.
    { Invoke-LogRotation -Path "$Script:TestDir\nonexistent" } | Should -Not -Throw
  }

  It 'is a no-op on files below MaxSize' {
    $logFile = Join-Path $Script:LogDir 'test.log'
    Set-Content -Path $logFile -Value 'small content'

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 1MB

    (Test-Path -LiteralPath $logFile -PathType Leaf) | Should -Be $true
    (Get-Item -LiteralPath $logFile).Length | Should -BeGreaterThan 0
  }

  It 'rotates a file exceeding MaxSize via copy-truncate' {
    $logFile = Join-Path $Script:LogDir 'test.log'
    # Create a file larger than 10 bytes.
    $content = 'a' * 100
    Set-Content -Path $logFile -Value $content

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 10 -MaxFiles 2 -Compress:$false

    $archive = Join-Path $Script:LogDir 'test.1.log'
    (Test-Path -LiteralPath $archive -PathType Leaf) | Should -Be $true
    (Test-Path -LiteralPath $logFile -PathType Leaf) | Should -Be $true
    (Get-Item -LiteralPath $logFile).Length | Should -Be 0
  }

  It 'shifts existing archives' {
    $logFile = Join-Path $Script:LogDir 'test.log'
    $content = 'a' * 100

    # Populate current log, .1, .2
    Set-Content -Path $logFile -Value $content
    Set-Content -Path "$Script:LogDir\test.1.log" -Value 'old1'
    Set-Content -Path "$Script:LogDir\test.2.log" -Value 'old2'

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 10 -MaxFiles 3 -Compress:$false

    # .1, .2, .3 should all exist after rotation
    (Test-Path -LiteralPath "$Script:LogDir\test.1.log" -PathType Leaf) | Should -Be $true
    (Test-Path -LiteralPath "$Script:LogDir\test.2.log" -PathType Leaf) | Should -Be $true
    (Test-Path -LiteralPath "$Script:LogDir\test.3.log" -PathType Leaf) | Should -Be $true
  }

  It 'removes oldest archive when at MaxFiles' {
    $logFile = Join-Path $Script:LogDir 'test.log'
    $content = 'a' * 100

    # Fill all slots: current, .1, .2, .3
    Set-Content -Path $logFile -Value $content
    Set-Content -Path "$Script:LogDir\test.1.log" -Value 'old1'
    Set-Content -Path "$Script:LogDir\test.2.log" -Value 'old2'
    Set-Content -Path "$Script:LogDir\test.3.log" -Value 'old3'

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 10 -MaxFiles 3 -Compress:$false

    # .4 must not exist
    (Test-Path -LiteralPath "$Script:LogDir\test.4.log" -PathType Leaf) | Should -Be $false
  }

  It 'rotates logs in subdirectories' {
    $subDir = Join-Path $Script:LogDir 'subsvc'
    New-Item -Path $subDir -ItemType Directory -Force > $null
    $logFile = Join-Path $subDir 'combined.log'
    Set-Content -Path $logFile -Value ('a' * 100)

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 10 -MaxFiles 2 -Compress:$false

  $archive = Join-Path $subDir 'combined.1.log'
    (Test-Path -LiteralPath $archive -PathType Leaf) | Should -Be $true
    (Get-Item -LiteralPath $logFile).Length | Should -Be 0
  }

  It 'does not rotate files without .log extension' {
    $nonLog = Join-Path $Script:LogDir 'data.txt'
    Set-Content -Path $nonLog -Value ('a' * 100)

    Invoke-LogRotation -Path $Script:LogDir -MaxSize 10 -MaxFiles 2 -Compress:$false

    # txt file should be untouched
    (Test-Path -LiteralPath $nonLog -PathType Leaf) | Should -Be $true
    (Test-Path -LiteralPath "$Script:LogDir\data.1.txt" -PathType Leaf) | Should -Be $false
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
$ensureLogDirPath = Join-Path \$PSScriptRoot '../../../src/hosts/Windows/modules/system/Invoke-EnsureLogDir.ps1'
    . $ensureLogDirPath

    $Script:TestServicesJson = Join-Path $env:TEMP 'nucleus-test-services.json'
    $Script:TestSystemLogDir = Join-Path $env:TEMP 'nucleus-test-system-log'
    $Script:TestUserLogDir = Join-Path $env:TEMP 'nucleus-test-user-log'
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

  Invoke-EnsureLogDir -ServicesJson \$Script:TestServicesJson

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
