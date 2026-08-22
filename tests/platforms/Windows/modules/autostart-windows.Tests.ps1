<#
.SYNOPSIS
  Pester tests for autostart.ps1 internal functions.

.DESCRIPTION
  Tests the AppRunKeyValueName, Resolve-AppNameList, Get-AppActualState,
  Enable-RunKeyEntry, and Disable-RunKeyEntry functions by sourcing the
  function definitions from autostart.ps1 with a mock $Registry.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/autostart-windows.Tests.ps1 -Passthru"
#>

BeforeAll {
  # Read autostart.ps1 and extract function definitions using the PowerShell AST parser.
  $autostartPs1Path = Join-Path $PSScriptRoot '../../../../src/scripts/autostart.ps1'
  $autostartPs1Content = Get-Content -Path $autostartPs1Path -Raw
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($autostartPs1Content, [ref]$tokens, [ref]$errors)

  # Extract all function definitions from the AST.
  $functionAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  $functionCode = ($functionAsts | ForEach-Object { $_.Extent.Text }) -join "`n"

  # Script-scoped mock Registry (models the filtered structure from autostart.ps1 main logic).
  $Script:Registry = @{
    'Parsec' = @{
      displayName = 'Parsec'
      hostEntry   = @{ platform = 'Windows'; autostartEnabled = $true; autostartDisableNative = $true; kind = 'run-key'; path = 'C:\Program Files\Parsec\parsec.exe' }
    }
    'Steam' = @{
      displayName = 'Steam'
      hostEntry   = @{ platform = 'Windows'; autostartEnabled = $false; autostartDisableNative = $true; kind = 'run-key'; path = 'C:\Program Files (x86)\Steam\steam.exe' }
    }
    'Telegram' = @{
      displayName = 'Telegram'
      hostEntry   = @{ platform = 'Windows'; autostartEnabled = $true; autostartDisableNative = $true; kind = 'startup-folder'; path = 'C:\Users\test\AppData\Telegram.exe' }
    }
  }

  # Pester v5 cannot Mock commands that do not exist in the session, so every
  # mocked command absent from non-Windows CI hosts needs a stub definition
  # first. Each Mock below overrides its stub.
  function Test-RunKeyEntry { throw 'stub: Test-RunKeyEntry' }
  function Write-NucleusInfo { param([string]$Message, [string]$CommandName) Write-Output "$CommandName : $Message" }
  function Write-NucleusError { param([string]$Message, [string]$CommandName) Write-Error "$CommandName : $Message" }

  # Write-Nucleus* helpers come from Format-NucleusOutput.psm1 (not dot-sourced
  # here); stub them to mirror production so Write-Error interception works.
  function Write-NucleusWarning { param([string]$Message, [string]$CommandName) Write-Warning "$CommandName : $Message" }

  # Script-scoped host (constant for Windows).
  $Script:NucleusHost = 'Windows'
  $NucleusHost = $Script:NucleusHost

  # Define the Run-key path constant that autostart.ps1 sets at script scope.
  $Script:RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $RunKeyPath = $Script:RunKeyPath

  # Dot-source the function definitions.
  . ([scriptblock]::Create($functionCode))
}

# ---------------------------------------------------------------------------
# AppRunKeyValueName
# ---------------------------------------------------------------------------

Describe 'AppRunKeyValueName' {
  It 'prefixes the app key with nucleus-' {
    $name = AppRunKeyValueName -Key 'Parsec'
    $name | Should -Be 'nucleus-Parsec'
  }

  It 'prefixes an arbitrary key' {
    $name = AppRunKeyValueName -Key 'Steam'
    $name | Should -Be 'nucleus-Steam'
  }
}

# ---------------------------------------------------------------------------
# Resolve-AppNameList
# ---------------------------------------------------------------------------

Describe 'Resolve-AppNameList' {
  It 'returns all registry entries when no names given' {
    $results = Resolve-AppNameList -Names @()
    $results.Count | Should -Be 3
    $results.ContainsKey('Parsec') | Should -BeTrue
    $results.ContainsKey('Steam') | Should -BeTrue
    $results.ContainsKey('Telegram') | Should -BeTrue
  }

  It 'returns only requested entries' {
    $results = Resolve-AppNameList -Names @('Parsec', 'Steam')
    $results.Count | Should -Be 2
    $results.ContainsKey('Parsec') | Should -BeTrue
    $results.ContainsKey('Steam') | Should -BeTrue
    $results.ContainsKey('Telegram') | Should -BeFalse
  }

  It 'marks unknown names with ERROR prefix' {
    $results = Resolve-AppNameList -Names @('DoesNotExist')
    $results.ContainsKey('ERROR:DoesNotExist') | Should -BeTrue
  }
}

# ---------------------------------------------------------------------------
# Get-AppActualState
# ---------------------------------------------------------------------------

Describe 'Get-AppActualState' {
  It 'reports enabled when Run-key entry present' {
    Mock Test-RunKeyEntry { return $true }
    $state = Get-AppActualState -Key 'Parsec' -Entry $Script:Registry['Parsec']
    $state | Should -Be 'enabled'
  }

  It 'reports disabled when Run-key entry absent' {
    Mock Test-RunKeyEntry { return $false }
    $state = Get-AppActualState -Key 'Parsec' -Entry $Script:Registry['Parsec']
    $state | Should -Be 'disabled'
  }
}

# ---------------------------------------------------------------------------
# Enable-RunKeyEntry / Disable-RunKeyEntry
# ---------------------------------------------------------------------------

Describe 'Enable-RunKeyEntry' {
  It 'writes the Run-key value via Set-ItemProperty' {
    $Script:written = $null
    Mock Test-Path { return $true }
    Mock Set-ItemProperty { param($Name, $Value) $Script:written = @{ Name = $Name; Value = $Value } }
    Mock New-Item { return $null }
    Enable-RunKeyEntry -Key 'Parsec' -Path 'C:\Program Files\Parsec\parsec.exe'
    $Script:written.Name | Should -Be 'nucleus-Parsec'
    $Script:written.Value | Should -Be 'C:\Program Files\Parsec\parsec.exe'
  }
}

Describe 'Disable-RunKeyEntry' {
  It 'removes the Run-key value when present' {
    $Script:removed = $null
    Mock Test-RunKeyEntry { return $true }
    Mock Remove-ItemProperty { param($Name) $Script:removed = $Name }
    Disable-RunKeyEntry -Key 'Parsec'
    $Script:removed | Should -Be 'nucleus-Parsec'
  }

  It 'does nothing when Run-key value absent' {
    $Script:removed = $null
    Mock Test-RunKeyEntry { return $false }
    Mock Remove-ItemProperty { param($Name) $Script:removed = $Name }
    Disable-RunKeyEntry -Key 'Parsec'
    $Script:removed | Should -BeNullOrEmpty
  }
}
