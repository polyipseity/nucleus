<#
.SYNOPSIS
    Tests for the PSGallery nupkg pin helpers (PsGalleryPin.ps1).
.DESCRIPTION
    `lockfile.json`'s `psgallery` object entries record the SHA256 of the module
    nupkg in SRI form, and the Windows updater recomputes that hash on every
    version bump, so the formatting has to be exactly what the Nix side records
    (`nix store prefetch-file --json --hash-type sha256`). A wrong encoding would
    silently pin a hash nothing can match.

    Only the pure hashing helper is covered here: Get-PsgalleryNupkgHash needs
    live PSGallery access, which is not available off-network. The values below
    are the SHA256 of fixed byte inputs, so they pin the encoding rather than
    the implementation.
.NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on failure
#>

Describe 'psgallery nupkg pin helpers' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..')).Path
        . (Join-Path -Path $script:repoRoot -ChildPath 'src\platforms\Windows\modules\lib\PsGalleryPin.ps1')
        $script:tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-psgallery-$([System.IO.Path]::GetRandomFileName())"
        $null = New-Item -ItemType Directory -Path $script:tmpDir -Force
    }

    AfterAll {
        Remove-Item -Path $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'formats the SHA256 of a file as SRI' {
        $file = Join-Path -Path $script:tmpDir -ChildPath 'abc.bin'
        [System.IO.File]::WriteAllBytes($file, [byte[]](0x61, 0x62, 0x63))
        Get-NucleusSriHash -Path $file | Should -Be 'sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='
    }

    It 'formats the SHA256 of an empty file as SRI' {
        $file = Join-Path -Path $script:tmpDir -ChildPath 'empty.bin'
        [System.IO.File]::WriteAllBytes($file, [byte[]]@())
        Get-NucleusSriHash -Path $file | Should -Be 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='
    }

    It 'refuses a missing file rather than returning a hash' {
        { Get-NucleusSriHash -Path (Join-Path -Path $script:tmpDir -ChildPath 'absent.bin') } | Should -Throw
    }
}
