<#
.SYNOPSIS
    Pester coverage for Sync-SafeDelete's clink resolution and shim manifest.
.DESCRIPTION
    Unit-tests Resolve-ClinkCommand: clink comes from the WinGet DSC entry
    chrisant996.Clink, and nothing in this repo adds a PATH entry for it, so
    whatever Clink's installer put on PATH is the whole search. The v1.9.35
    release archive ships clink.bat, not clink.exe, so clink wins when both
    names resolve, clink_x64 is honoured when only the suffixed binary is
    present, and absence returns $null.

    Unit-tests Write-SafeDeleteShimsManifest against temp directories: the
    manifest is the proof the deletion filter reads, so it carries rip.exe's
    SHA256 and one entry per deployed copy, sorted and byte-identical across
    runs.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'Resolve-ClinkCommand' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\platforms\Windows\modules\user\Sync-SafeDelete.ps1')
    }

    It 'resolves clink from PATH when both names resolve' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink.bat' } } -ParameterFilter { $Name -eq 'clink' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink_x64.exe' } } -ParameterFilter { $Name -eq 'clink_x64' }

        Resolve-ClinkCommand | Should -Be 'C:\Program Files\Clink\clink.bat'
    }

    It 'honours clink_x64 when clink itself is absent' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'clink' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Clink\clink_x64.exe' } } -ParameterFilter { $Name -eq 'clink_x64' }

        Resolve-ClinkCommand | Should -Be 'C:\Program Files\Clink\clink_x64.exe'
    }

    It 'returns $null when neither clink nor clink_x64 resolves' {
        Mock Get-Command { } -ParameterFilter { $Name -in @('clink', 'clink_x64') }

        Resolve-ClinkCommand | Should -BeNullOrEmpty
    }
}

Describe 'Write-SafeDeleteShimsManifest' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\platforms\Windows\modules\user\Sync-SafeDelete.ps1')
        $script:ShimNameList = @('del.exe', 'erase.exe', 'rd.exe', 'ri.exe', 'rm.exe', 'rmdir.exe')
    }

    BeforeEach {
        $script:Root = Join-Path -Path ([System.IO.Path]::GetTempPath()) ("nucleus-safe-delete-" + [guid]::NewGuid().ToString('N'))
        $script:UserRoot = Join-Path -Path $script:Root -ChildPath 'nucleus'
        $script:BinDir = Join-Path -Path $script:UserRoot -ChildPath 'bin'
        $script:ShimDir = Join-Path -Path (Join-Path -Path $script:Root -ChildPath '.local') -ChildPath 'bin'
        $script:RipExe = Join-Path -Path $script:Root -ChildPath 'rip.exe'
        $script:ManifestPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $script:UserRoot -ChildPath 'state') -ChildPath 'safe-delete') -ChildPath 'shims.json'
        foreach ($dir in @($script:BinDir, $script:ShimDir)) {
            New-Item -ItemType Directory -Path $dir -Force > $null
        }
        Set-Content -LiteralPath $script:RipExe -Value 'rip.exe fixture bytes' -NoNewline
        foreach ($name in $script:ShimNameList) {
            Copy-Item -LiteralPath $script:RipExe -Destination (Join-Path -Path $script:BinDir -ChildPath $name)
            Copy-Item -LiteralPath $script:RipExe -Destination (Join-Path -Path $script:ShimDir -ChildPath $name)
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Root) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup in test teardown, a failure is acceptable
        }
    }

    It 'writes one sorted entry per deployed copy with rip.exe''s hash' {
        Write-SafeDeleteShimsManifest -UserRoot $script:UserRoot -RipExe $script:RipExe -BinDir $script:BinDir -ShimDir $script:ShimDir

        Test-Path -LiteralPath $script:ManifestPath | Should -BeTrue
        $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $manifest.version | Should -Be 1
        $manifest.ripHash | Should -Match '^[0-9a-f]{64}$'
        $manifest.ripHash | Should -Be (Get-FileHash -LiteralPath $script:RipExe -Algorithm SHA256).Hash.ToLowerInvariant()

        $shims = @($manifest.shims)
        $shims.Count | Should -Be 12
        foreach ($name in $script:ShimNameList) {
            @($shims | Where-Object { $_.name -eq $name }).Count | Should -Be 2
        }
        foreach ($shim in $shims) {
            [System.IO.Path]::IsPathRooted([string]$shim.path) | Should -BeTrue
            Test-Path -LiteralPath ([string]$shim.path) -PathType Leaf | Should -BeTrue
        }

        # WHY re-sort: the natural build order groups by directory, so an unsorted
        # manifest fails the comparison while a sorted one survives its own sort.
        $written = ($shims | ForEach-Object { "$($_.name)|$($_.path)" }) -join "`n"
        $sorted = (@($shims) | Sort-Object -Property name, path | ForEach-Object { "$($_.name)|$($_.path)" }) -join "`n"
        $written | Should -Be $sorted
    }

    It 'writes identical bytes on a second call' {
        Write-SafeDeleteShimsManifest -UserRoot $script:UserRoot -RipExe $script:RipExe -BinDir $script:BinDir -ShimDir $script:ShimDir
        $first = Get-Content -LiteralPath $script:ManifestPath -Raw

        Write-SafeDeleteShimsManifest -UserRoot $script:UserRoot -RipExe $script:RipExe -BinDir $script:BinDir -ShimDir $script:ShimDir
        $second = Get-Content -LiteralPath $script:ManifestPath -Raw

        $second | Should -Be $first
    }

    It 'throws instead of writing a manifest when rip.exe is missing' {
        $missing = Join-Path -Path $script:Root -ChildPath 'absent.exe'

        { Write-SafeDeleteShimsManifest -UserRoot $script:UserRoot -RipExe $missing -BinDir $script:BinDir -ShimDir $script:ShimDir } | Should -Throw
        Test-Path -LiteralPath $script:ManifestPath | Should -BeFalse
    }
}
