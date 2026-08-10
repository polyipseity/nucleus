<#
.SYNOPSIS
    Pester coverage for the backup/restore helpers in Sync-GitAndSshConfig.ps1.
.DESCRIPTION
    Unit-tests Save-RegularFileBackup and Restore-FileBackup on temp paths:
    the enable-side backup-once semantics (regular file moved to a same-folder
    .bak on first replacement; a stale .bak is never overwritten; symlink
    untouched) and the disable-side lossless restore (symlink removed,
    .bak restored when present, nothing left when absent, unmanaged regular
    file left alone).
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows.
#>

Describe 'Sync-GitAndSshConfig backup/restore helpers' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\..\src\platforms\Windows\modules\user\Sync-GitAndSshConfig.ps1')
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-gitcfg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force > $null
    }
    AfterAll {
        Remove-Item -Path $script:testDir -Recurse -Force
    }

    Context 'Save-RegularFileBackup (enable side)' {
        It 'moves a pre-existing regular file to a same-folder .bak' {
            $target = Join-Path $script:testDir 'gitconfig'
            $backup = "$target.bak"
            Set-Content -Path $target -Value 'installer-owned original' -NoNewline
            Save-RegularFileBackup -Path $target -BackupPath $backup
            Test-Path -Path $target | Should -Be $false
            Test-Path -Path $backup | Should -Be $true
            Get-Content -Path $backup -Raw | Should -Be 'installer-owned original'
        }

        It 'leaves a managed symlink untouched' {
            $target = Join-Path $script:testDir 'symlinked'
            $backup = "$target.bak"
            $source = Join-Path $script:testDir 'symlink-source'
            Set-Content -Path $source -Value 'managed content' -NoNewline
            New-Item -ItemType SymbolicLink -Path $target -Target $source -Force > $null
            Save-RegularFileBackup -Path $target -BackupPath $backup
            Test-Path -Path $backup | Should -Be $false
            $isSymlink = [bool]((Get-Item -Path $target -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            $isSymlink | Should -Be $true
        }

        It 'is a no-op when nothing exists at the target' {
            $target = Join-Path $script:testDir 'absent'
            $backup = "$target.bak"
            Save-RegularFileBackup -Path $target -BackupPath $backup
            Test-Path -Path $backup | Should -Be $false
        }

        It 'does not overwrite a stale .bak (backup-once)' {
            $target = Join-Path $script:testDir 'stale-bak'
            $backup = "$target.bak"
            Set-Content -Path $target -Value 'newer installer copy' -NoNewline
            Set-Content -Path $backup -Value 'first original' -NoNewline
            Save-RegularFileBackup -Path $target -BackupPath $backup
            # First original wins: the stale .bak is preserved and the newer
            # copy stays for the symlink to replace (-Force, ln -sf parity).
            Test-Path -Path $target | Should -Be $true
            Get-Content -Path $target -Raw | Should -Be 'newer installer copy'
            Get-Content -Path $backup -Raw | Should -Be 'first original'
        }
    }

    Context 'Restore-FileBackup (disable side)' {
        It 'removes the symlink and restores the .bak' {
            $target = Join-Path $script:testDir 'restore-me'
            $backup = "$target.bak"
            $source = Join-Path $script:testDir 'restore-source'
            Set-Content -Path $backup -Value 'original content' -NoNewline
            Set-Content -Path $source -Value 'managed content' -NoNewline
            New-Item -ItemType SymbolicLink -Path $target -Target $source -Force > $null
            Restore-FileBackup -Path $target -BackupPath $backup
            $isSymlink = [bool]((Get-Item -Path $target -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            $isSymlink | Should -Be $false
            Get-Content -Path $target -Raw | Should -Be 'original content'
            Test-Path -Path $backup | Should -Be $false
        }

        It 'with no .bak removes the symlink and leaves nothing' {
            $target = Join-Path $script:testDir 'no-bak'
            $backup = "$target.bak"
            $source = Join-Path $script:testDir 'no-bak-source'
            Set-Content -Path $source -Value 'managed content' -NoNewline
            New-Item -ItemType SymbolicLink -Path $target -Target $source -Force > $null
            Restore-FileBackup -Path $target -BackupPath $backup
            Test-Path -Path $target | Should -Be $false
            Test-Path -Path $backup | Should -Be $false
        }

        It 'restores the .bak when the target is already absent' {
            $target = Join-Path $script:testDir 'already-gone'
            $backup = "$target.bak"
            Set-Content -Path $backup -Value 'original content' -NoNewline
            Restore-FileBackup -Path $target -BackupPath $backup
            Get-Content -Path $target -Raw | Should -Be 'original content'
            Test-Path -Path $backup | Should -Be $false
        }

        It 'leaves an unmanaged regular file and its .bak untouched' {
            $target = Join-Path $script:testDir 'unmanaged'
            $backup = "$target.bak"
            Set-Content -Path $target -Value 'newer installer file' -NoNewline
            Set-Content -Path $backup -Value 'stale original' -NoNewline
            Restore-FileBackup -Path $target -BackupPath $backup
            Get-Content -Path $target -Raw | Should -Be 'newer installer file'
            Get-Content -Path $backup -Raw | Should -Be 'stale original'
        }
    }
}
