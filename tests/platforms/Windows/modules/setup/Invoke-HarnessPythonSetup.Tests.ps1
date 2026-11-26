<#
.SYNOPSIS
    Pester coverage for the managed harness Python venv setup.
.DESCRIPTION
    Drives the real setup module against a recording uv shim, a temp USER root,
    and a synthetic lockfile. No package is installed and no real uv is called.
    The cases prove venv creation, idempotence, hard failure on a missing uv or
    failed install, and that the harness resolver prefers the managed
    interpreter over PATH.
.NOTES
    Environment variables: LOCALAPPDATA, NUCLEUS_REPO_ROOT, PATH, UV_FAIL_PIP
    are overridden for the suite and restored in AfterAll.
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Invoke-HarnessPythonSetup harness Python convergence' {
    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\ManagedPaths.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\setup\Invoke-HarnessPythonSetup.ps1')
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-HarnessModels.ps1')

        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-harness-python-" + [guid]::NewGuid().ToString('N'))
        $script:shimDir = Join-Path $script:tempRoot 'shim'
        $script:emptyDir = Join-Path $script:tempRoot 'empty'
        $script:userRoot = Join-Path $script:tempRoot 'LOCALAPPDATA\nucleus'
        $script:lockfilePath = Join-Path $script:tempRoot 'lockfile.json'
        $script:uvLog = Join-Path $script:tempRoot 'uv-calls.log'
        foreach ($dir in @($script:shimDir, $script:emptyDir, $script:userRoot)) {
            $null = New-Item -ItemType Directory -Path $dir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        }
        @{ uv = [ordered]@{ pyyaml = '6.0.3' } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:lockfilePath

        if ($IsWindows) {
            $shimBody = "@echo off`r`necho %* >> `"$script:uvLog`"`r`nif `"%~1`"==`"venv`" (`r`n  if not exist `"%~2\\Scripts`" mkdir `"%~2\\Scripts`"`r`n  type nul > `"%~2\\Scripts\\python.exe`"`r`n)`r`nif `"%~1`"==`"pip`" if `"%UV_FAIL_PIP%`"==`"1`" exit /b 7`r`nexit /b 0`r`n"
            $null = Set-Content -Path (Join-Path $script:shimDir 'uv.cmd') -Value $shimBody -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        } else {
            $shimBody = "#!/bin/sh`necho `"`$*`" >> '$script:uvLog'`nif [ `"`$1`" = venv ]; then mkdir -p `"`$2/Scripts`"; : > `"`$2/Scripts/python.exe`"; fi`nif [ `"`$1`" = pip ] && [ `"`$UV_FAIL_PIP`" = 1 ]; then exit 7; fi`nexit 0`n"
            $shimPath = Join-Path $script:shimDir 'uv'
            $null = Set-Content -Path $shimPath -Value $shimBody -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            [System.IO.File]::SetUnixFileMode($shimPath, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        }
        $script:uvShimPath = if ($IsWindows) { Join-Path $script:shimDir 'uv.cmd' } else { Join-Path $script:shimDir 'uv' }

        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:originalRepoRoot = $env:NUCLEUS_REPO_ROOT
        $script:originalPath = $env:PATH
        $script:originalFailPip = $env:UV_FAIL_PIP
        $env:LOCALAPPDATA = Join-Path $script:tempRoot 'LOCALAPPDATA'
        $env:NUCLEUS_REPO_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
        $env:PATH = "$script:shimDir$([System.IO.Path]::PathSeparator)$env:PATH"

        function Clear-UvState {
            if (Test-Path -LiteralPath $script:uvLog) { Remove-Item -LiteralPath $script:uvLog -Force }
            $venvDir = Join-Path -Path $script:userRoot -ChildPath 'envs\harness-python'
            if (Test-Path -LiteralPath $venvDir) {
                Remove-Item -LiteralPath $venvDir -Recurse -Force
            }
            $env:UV_FAIL_PIP = '0'
        }

        function Get-UvCallList {
            if (-not (Test-Path -LiteralPath $script:uvLog)) { return @() }
            return @(Get-Content -LiteralPath $script:uvLog | ForEach-Object { $_.TrimEnd() })
        }
    }

    BeforeEach {
        # The setup module prepends the venv Scripts dir to PATH, so reset the
        # search order before each case to keep the recording shim first.
        $env:PATH = "$script:shimDir$([System.IO.Path]::PathSeparator)$script:originalPath"
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:originalLocalAppData
        $env:NUCLEUS_REPO_ROOT = $script:originalRepoRoot
        $env:PATH = $script:originalPath
        if ($null -eq $script:originalFailPip) {
            Remove-Item Env:UV_FAIL_PIP -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
        } else {
            $env:UV_FAIL_PIP = $script:originalFailPip
        }
        if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
            # check-suppress:suppression_doc: cleanup in test teardown -- failure is acceptable
            Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates the venv, installs the pinned PyYAML, and prepends the venv Scripts directory' {
        Clear-UvState
        $venvPython = Get-NucleusHarnessPythonExe -UserRoot $script:userRoot
        $venvScripts = Split-Path -Path $venvPython -Parent

        $result = Invoke-HarnessPythonSetup -UserRoot $script:userRoot -LockfilePath $script:lockfilePath -UvPath $script:uvShimPath

        $result.VenvPython | Should -Be $venvPython
        $result.PyYamlVersion | Should -Be '6.0.3'
        Test-Path -LiteralPath $venvPython -PathType Leaf | Should -BeTrue
        $calls = Get-UvCallList
        @($calls | Where-Object { $_ -like 'venv *' }).Count | Should -Be 1
        $calls | Should -Contain "pip install --python $venvPython pyyaml==6.0.3"
        $env:PATH | Should -Match ([regex]::Escape($venvScripts))
    }

    It 'does not recreate the venv on a second run' {
        Clear-UvState

        Invoke-HarnessPythonSetup -UserRoot $script:userRoot -LockfilePath $script:lockfilePath -UvPath $script:uvShimPath > $null
        Invoke-HarnessPythonSetup -UserRoot $script:userRoot -LockfilePath $script:lockfilePath -UvPath $script:uvShimPath > $null

        $calls = Get-UvCallList
        @($calls | Where-Object { $_ -like 'venv *' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like 'pip *' }).Count | Should -Be 2
    }

    It 'throws when uv is missing instead of falling back to a system interpreter' {
        Clear-UvState
        $savedPath = $env:PATH
        try {
            $env:PATH = $script:emptyDir

            { Invoke-HarnessPythonSetup -UserRoot $script:userRoot -LockfilePath $script:lockfilePath } | Should -Throw '*uv not found*'
            @(Get-UvCallList) | Should -BeNullOrEmpty
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'throws when the pinned PyYAML install fails' {
        Clear-UvState
        $env:UV_FAIL_PIP = '1'

        $failure = { Invoke-HarnessPythonSetup -UserRoot $script:userRoot -LockfilePath $script:lockfilePath -UvPath $script:uvShimPath } | Should -Throw -PassThru

        $failure.Exception.Message | Should -BeLike '*pyyaml==6.0.3*failed (exit 7)*'
        $env:UV_FAIL_PIP = '0'
    }

    It 'prefers the managed interpreter over a PATH python' {
        Clear-UvState
        $managedPython = Get-NucleusHarnessPythonExe -UserRoot $script:userRoot
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $managedPython -Parent) -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        $null = Set-Content -LiteralPath $managedPython -Value 'managed'  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        $pathPythonDir = Join-Path $script:tempRoot 'path-python'
        $null = New-Item -ItemType Directory -Path $pathPythonDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded in test setup
        if ($IsWindows) {
            $null = Set-Content -Path (Join-Path $pathPythonDir 'python3.cmd') -Value '@echo off' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
        } else {
            $pathPython = Join-Path $pathPythonDir 'python3'
            $null = Set-Content -Path $pathPython -Value '#!/bin/sh' -NoNewline  # check-suppress:suppression_doc: Set-Content returns nothing useful, discarded in test setup
            [System.IO.File]::SetUnixFileMode($pathPython, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        }
        $savedPath = $env:PATH
        try {
            $env:PATH = "$pathPythonDir$([System.IO.Path]::PathSeparator)$env:PATH"

            Resolve-HarnessPythonExe | Should -Be $managedPython
        } finally {
            $env:PATH = $savedPath
        }
    }
}
