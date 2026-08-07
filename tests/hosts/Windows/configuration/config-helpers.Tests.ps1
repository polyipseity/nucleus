<#
.SYNOPSIS
    Pester coverage for the shared config deployment helpers in ConfigHelpers.ps1.
.DESCRIPTION
    Unit-tests Resolve-UserConfigSource (per-user overlay resolution with
    src/users/default fallback, mirroring users-overlay.nix on POSIX) and
    Deploy-WritableSymlink (Method 1 writable symlink creation returning a
    Changed/Message result) on temp paths.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
    Symlink creation requires elevation or Developer Mode on Windows; not
    required on macOS/Linux where the tests also run.
#>

Describe 'Resolve-UserConfigSource' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\ConfigHelpers.ps1')
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cfghlpr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force > $null
    }
    AfterAll {
        Remove-Item -Path $script:testDir -Recurse -Force
    }

    It 'returns the per-user file when it exists (over the default)' {
        $user = 'alice'
        $config = 'git'
        $path = Join-Path $script:testDir "src/users/$user/$config/Windows.gitconfig"
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force > $null
        Set-Content -Path $path -Value 'per-user content' -NoNewline
        $defaultPath = Join-Path $script:testDir "src/users/default/$config/Windows.gitconfig"
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force > $null
        Set-Content -Path $defaultPath -Value 'default content' -NoNewline
        $resolved = Resolve-UserConfigSource -User $user -ConfigName $config -Extension 'gitconfig' -HostName 'Windows' -RepoRoot $script:testDir
        $resolved | Should -Be $path
    }

    It 'falls back to the default file when the per-user file is missing' {
        $config = 'ssh'
        $defaultPath = Join-Path $script:testDir "src/users/default/$config/Windows.config"
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force > $null
        Set-Content -Path $defaultPath -Value 'default content' -NoNewline
        $resolved = Resolve-UserConfigSource -User 'bob' -ConfigName $config -Extension 'config' -HostName 'Windows' -RepoRoot $script:testDir
        $resolved | Should -Be $defaultPath
    }

    It 'throws when neither the per-user nor the default file exists' {
        { Resolve-UserConfigSource -User 'carol' -ConfigName 'missing' -Extension 'toml' -HostName 'Windows' -RepoRoot $script:testDir } | Should -Throw
    }
}

Describe 'Resolve-UserConfigFile' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\ConfigHelpers.ps1')
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cfgfile-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force > $null
    }
    AfterAll {
        Remove-Item -Path $script:testDir -Recurse -Force
    }

    It 'returns the per-user overlay file when it exists' {
        $user = 'alice'
        $path = Join-Path $script:testDir "src/users/$user/starship/starship.toml"
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force > $null
        Set-Content -Path $path -Value 'per-user content' -NoNewline
        $defaultPath = Join-Path $script:testDir "src/users/default/starship/starship.toml"
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force > $null
        Set-Content -Path $defaultPath -Value 'default content' -NoNewline
        $resolved = Resolve-UserConfigFile -User $user -ConfigName 'starship' -RelativePath 'starship.toml' -RepoRoot $script:testDir
        $resolved | Should -Be $path
    }

    It 'falls back to the default overlay file when the per-user file is missing' {
        $defaultPath = Join-Path $script:testDir "src/users/default/obsidian/obsidian.json"
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force > $null
        Set-Content -Path $defaultPath -Value '{}' -NoNewline
        $resolved = Resolve-UserConfigFile -User 'bob' -ConfigName 'obsidian' -RelativePath 'obsidian.json' -RepoRoot $script:testDir
        $resolved | Should -Be $defaultPath
    }
}

Describe 'Resolve-UserConfigFirstLevelEntry' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\ConfigHelpers.ps1')
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cfgdir-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force > $null
    }
    AfterAll {
        Remove-Item -Path $script:testDir -Recurse -Force
    }

    It 'returns the per-user first-level entry when it exists' {
        $user = 'alice'
        $path = Join-Path $script:testDir "src/users/$user/vscode/settings.json"
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force > $null
        Set-Content -Path $path -Value '{}' -NoNewline
        $defaultPath = Join-Path $script:testDir "src/users/default/vscode/settings.json"
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force > $null
        Set-Content -Path $defaultPath -Value '{}' -NoNewline
        $resolved = Resolve-UserConfigFirstLevelEntry -User $user -ConfigName 'vscode' -EntryName 'settings.json' -RepoRoot $script:testDir
        $resolved | Should -Be $path
    }

    It 'lists merged first-level entry names' {
        $defaultDir = Join-Path $script:testDir "src/users/default/cursor"
        New-Item -ItemType Directory -Path $defaultDir -Force > $null
        Set-Content -Path (Join-Path $defaultDir 'hooks.json') -Value '{}' -NoNewline
        $entries = Get-UserConfigFirstLevelEntryList -User 'bob' -ConfigName 'cursor' -RepoRoot $script:testDir
        $entries | Should -Contain 'hooks.json'
    }
}

Describe 'Deploy-WritableSymlink' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\ConfigHelpers.ps1')
        $script:symlinkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cfgdpl-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:symlinkDir -Force > $null
    }
    AfterAll {
        Remove-Item -Path $script:symlinkDir -Recurse -Force
    }

    It 'creates a symbolic link at the target pointing to the repo file and returns the Changed/Message result' {
        $repoFile = Join-Path $script:symlinkDir 'starship.toml'
        Set-Content -Path $repoFile -Value 'managed content' -NoNewline
        $target = Join-Path $script:symlinkDir 'linked.toml'
        $result = Deploy-WritableSymlink -Name 'starship' -RepoRoot $script:symlinkDir -RepoRelPath 'starship.toml' -TargetPath $target
        $result.Changed | Should -Be $true
        $result.Message | Should -Not -BeNullOrEmpty
        Test-Path -Path $target -PathType Leaf | Should -Be $true
        $item = Get-Item -Path $target -Force
        $item.LinkType | Should -Be 'SymbolicLink'
        $resolvedTarget = [System.IO.Path]::GetFullPath($item.Target)
        $resolvedRepoFile = [System.IO.Path]::GetFullPath($repoFile)
        $resolvedTarget | Should -Be $resolvedRepoFile
    }
}

Describe 'Wallpaper path helpers' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\src\hosts\Windows\modules\ConfigHelpers.ps1')
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-wallpaper-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force > $null
        $encryptedDir = Join-Path $script:testDir 'src/users/alice/wallpapers/encrypted'
        New-Item -ItemType Directory -Path $encryptedDir -Force > $null
        Set-Content -Path (Join-Path $encryptedDir 'foo.png.sops') -Value 'blob' -NoNewline
        $wallpapersDir = Join-Path $script:testDir 'src/users/default/wallpapers/wallpapers'
        New-Item -ItemType Directory -Path $wallpapersDir -Force > $null
        Set-Content -Path (Join-Path $wallpapersDir 'bar.jpg') -Value 'image' -NoNewline
    }
    AfterAll {
        Remove-Item -Path $script:testDir -Recurse -Force
    }

    It 'lists encrypted wallpaper blobs' {
        $blobs = Get-WallpaperEncryptedBlobList -User 'alice' -RepoRoot $script:testDir
        $blobs | Should -Contain 'foo.png.sops'
    }

    It 'resolves encrypted wallpaper blob paths' {
        $resolved = Resolve-WallpaperEncryptedBlob -User 'alice' -BlobName 'foo.png.sops' -RepoRoot $script:testDir
        $resolved | Should -Be (Join-Path $script:testDir 'src/users/alice/wallpapers/encrypted/foo.png.sops')
    }

    It 'lists unencrypted wallpaper files from default overlay' {
        $files = Get-WallpaperUnencryptedFileList -User 'bob' -RepoRoot $script:testDir
        $files | Should -Contain 'bar.jpg'
    }

    It 'resolves unencrypted wallpaper file paths' {
        $resolved = Resolve-WallpaperUnencryptedFile -User 'bob' -FileName 'bar.jpg' -RepoRoot $script:testDir
        $resolved | Should -Be (Join-Path $script:testDir 'src/users/default/wallpapers/wallpapers/bar.jpg')
    }
}
