<#
.SYNOPSIS
    Pester coverage for the Windows harness model provisioning module.
.DESCRIPTION
    Drives Sync-HarnessModel against a fixture registry, home directory, and a
    Python stub. The assertions cover harness selection, host-split path
    selection, absent harness skips, hard errors, and merge failure propagation.
.NOTES
    Environment variables: a temporary Python stub log and exit code are set at
    script scope and restored afterward.
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Sync-HarnessModel' {
    BeforeAll {
        $script:moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules'
        Import-Module (Join-Path -Path $script:moduleRoot -ChildPath 'Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $script:moduleRoot -ChildPath 'user\Sync-HarnessModels.ps1')

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nucleus-harness-models-' + [guid]::NewGuid().ToString('N'))
        $script:repoRoot = Join-Path -Path $script:tempRoot -ChildPath 'repo'
        $script:homeDir = Join-Path -Path $script:tempRoot -ChildPath 'home'
        $script:emptyHome = Join-Path -Path $script:tempRoot -ChildPath 'empty-home'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:repoRoot -ChildPath 'src\modules\configs') -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:repoRoot -ChildPath 'src\scripts\agents') -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:homeDir -ChildPath '.pi\agent') -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:homeDir -ChildPath 'AppData\Roaming\Code\User') -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = New-Item -ItemType Directory -Path $script:emptyHome -Force # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup

        $registry = @{
            version    = 1
            harnesses = @(
                @{
                    harness = 'pi'
                    path    = '~/.pi/agent/models.json'
                    format  = 'json'
                    slot    = @{ kind = 'dotted-key'; path = 'providers.litellm' }
                    payload = 'src/users/default/pi/litellm-models.json'
                }
                @{
                    harness = 'vscode'
                    path    = @{
                        MacBook = '~/Library/Application Support/Code/User/chatLanguageModels.json'
                        NixOS   = '~/.config/Code/User/chatLanguageModels.json'
                        Windows = '~/AppData/Roaming/Code/User/chatLanguageModels.json'
                    }
                    format  = 'json'
                    slot    = @{ kind = 'named-array-item'; arrayPath = '$'; matchKey = 'name'; matchValue = 'LiteLLM' }
                    payload = 'src/users/default/vscode/litellm-entry.json'
                }
                @{
                    harness = 'copilot'
                    path    = '~/.copilot/providers.json'
                    format  = 'json'
                    slot    = @{ kind = 'dotted-key'; path = 'providers.litellm' }
                    payload = 'src/users/default/copilot/litellm-providers.json'
                }
            )
        }
        $script:registryPath = Join-Path -Path $script:repoRoot -ChildPath 'src\modules\configs\harness-models.json'
        $registry | ConvertTo-Json -Depth 8 | Set-Content -Path $script:registryPath
        $toolPath = Join-Path -Path $script:repoRoot -ChildPath 'src\scripts\agents\merge-harness-models.py'
        Set-Content -Path $toolPath -Value '# Python stub: the module only checks that the tool exists.'

        $script:pythonStub = Join-Path -Path $script:tempRoot -ChildPath 'python-stub.ps1'
        Set-Content -Path $script:pythonStub -Value @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
if ($env:HARNESS_PY_ARGS_LOG) {
  Add-Content -LiteralPath $env:HARNESS_PY_ARGS_LOG -Value ($Rest -join "`n")
}
if ($env:HARNESS_PY_EXIT) {
  exit [int]$env:HARNESS_PY_EXIT
}
'@
        $script:argsLog = Join-Path -Path $script:tempRoot -ChildPath 'python-args.log'
        Set-Content -Path $script:argsLog -Value ''
        $env:HARNESS_PY_ARGS_LOG = $script:argsLog
        $script:originalPyExit = $env:HARNESS_PY_EXIT
    }

    AfterAll {
        $env:HARNESS_PY_EXIT = $script:originalPyExit
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'merges only installed harnesses and only the current host path' {
        Set-Content -Path $script:argsLog -Value ''
        @(Sync-HarnessModel -Enabled:$true -RepoRoot $script:repoRoot -PythonExe $script:pythonStub -HostName 'Windows' -HomeDirectory $script:homeDir) > $null

        $argsText = Get-Content -LiteralPath $script:argsLog -Raw
        $argsText | Should -Match -- '--harness\s+pi'
        $argsText | Should -Match -- '--harness\s+vscode'
        $argsText | Should -Not -Match -- '--harness\s+copilot'
        $argsText | Should -Match -- '--host\s+Windows'
        $argsText | Should -Match -- "--home\s+$([regex]::Escape($script:homeDir))"
        $argsText | Should -Match -- "--registry\s+$([regex]::Escape($script:registryPath))"
        (Test-Path -LiteralPath (Join-Path -Path $script:homeDir -ChildPath '.copilot')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path -Path $script:homeDir -ChildPath 'Library')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path -Path $script:homeDir -ChildPath '.config')) | Should -BeFalse
    }

    It 'reports and skips every harness when no config directory exists' {
        Set-Content -Path $script:argsLog -Value ''
        $lines = @(Sync-HarnessModel -Enabled:$true -RepoRoot $script:repoRoot -PythonExe $script:pythonStub -HostName 'Windows' -HomeDirectory $script:emptyHome)
        ($lines -join "`n") | Should -Match 'no installed harness config directories'
        (Get-Content -LiteralPath $script:argsLog -Raw).Trim() | Should -BeNullOrEmpty
        (Get-ChildItem -LiteralPath $script:emptyHome -Force | Measure-Object).Count | Should -Be 0
    }

    It 'fails hard when the registry is missing' {
        { Sync-HarnessModel -Enabled:$true -RepoRoot $script:tempRoot -PythonExe $script:pythonStub -HostName 'Windows' -HomeDirectory $script:homeDir } | Should -Throw
    }

    It 'fails hard when the Python interpreter is missing' {
        $missingPython = Join-Path -Path $script:tempRoot -ChildPath 'no-python.exe'
        { Sync-HarnessModel -Enabled:$true -RepoRoot $script:repoRoot -PythonExe $missingPython -HostName 'Windows' -HomeDirectory $script:homeDir } | Should -Throw
    }

    It 'propagates a non-zero merge exit code' {
        Set-Content -Path $script:argsLog -Value ''
        $env:HARNESS_PY_EXIT = '3'
        try {
            { Sync-HarnessModel -Enabled:$true -RepoRoot $script:repoRoot -PythonExe $script:pythonStub -HostName 'Windows' -HomeDirectory $script:homeDir } | Should -Throw
        }
        finally {
            $env:HARNESS_PY_EXIT = $script:originalPyExit
        }
    }

    It 'does nothing when disabled' {
        Set-Content -Path $script:argsLog -Value ''
        @(Sync-HarnessModel -Enabled:$false -RepoRoot $script:repoRoot -PythonExe $script:pythonStub -HostName 'Windows' -HomeDirectory $script:homeDir) > $null
        (Get-Content -LiteralPath $script:argsLog -Raw).Trim() | Should -BeNullOrEmpty
    }
}
