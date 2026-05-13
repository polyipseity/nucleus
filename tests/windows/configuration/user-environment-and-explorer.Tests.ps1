# tests/windows/configuration/user-environment-and-explorer.Tests.ps1 — Pester
# coverage for user-scoped DSC registry and environment state.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\helpers\WindowsTestHelpers.ps1')
}

Describe "Windows User Configuration Parity" {
    Context "Screen saver and wallpaper posture" {
        It "Should enable the screen saver" {
            Get-NucleusRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive' | Should -Be '1'
        }

        It "Should require a password on screen saver resume" {
            Get-NucleusRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaverIsSecure' | Should -Be '1'
        }

        It "Should use a 60-second screen saver timeout" {
            Get-NucleusRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveTimeOut' | Should -Be '60'
        }

        It "Should materialize wallpapers under the managed pictures directory" {
            $wallpaperPath = Get-NucleusRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper'
            $wallpaperPath | Should -Match ([regex]::Escape((Join-Path -Path $env:USERPROFILE -ChildPath 'Pictures\wallpapers')))
        }

        It "Should create the managed wallpaper directory" {
            Test-Path -Path (Join-Path -Path $env:USERPROFILE -ChildPath 'Pictures\wallpapers') | Should -Be $true
        }
    }

    Context "Explorer visibility and taskbar chrome" {
        It "Should show hidden files" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' | Should -Be 1
        }

        It "Should show file extensions" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' | Should -Be 0
        }

        It "Should show all folders in the Explorer navigation pane" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'NavPaneShowAllFolders' | Should -Be 1
        }

        It "Should hide the taskbar search box" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' | Should -Be 0
        }

        It "Should keep the Explorer status bar visible" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowStatusBar' | Should -Be 1
        }

        It "Should show protected operating-system files" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSuperHidden' | Should -Be 1
        }

        It "Should suppress sync provider notifications" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' | Should -Be 0
        }

        It "Should hide the Task View button" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' | Should -Be 0
        }

        It "Should hide the Widgets taskbar button" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' | Should -Be 0
        }

        It "Should hide the Meet Now taskbar button" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' | Should -Be 0
        }

        It "Should show the full path in Explorer title bars" {
            Get-NucleusRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' -Name 'FullPath' | Should -Be 1
        }
    }

    Context "User environment variables" {
        It "Should set EDITOR to nvim" {
            Get-NucleusUserEnvironmentVariable -Name 'EDITOR' | Should -Be 'nvim'
        }

        It "Should set VISUAL to nvim" {
            Get-NucleusUserEnvironmentVariable -Name 'VISUAL' | Should -Be 'nvim'
        }

        It "Should set HOME to the current user profile" {
            Get-NucleusUserEnvironmentVariable -Name 'HOME' | Should -Be $env:USERPROFILE
        }

        It "Should set NIX_PATH to the flake registry alias" {
            Get-NucleusUserEnvironmentVariable -Name 'NIX_PATH' | Should -Be 'nixpkgs=flake:nixpkgs'
        }

        It "Should enable Ollama flash attention" {
            Get-NucleusUserEnvironmentVariable -Name 'OLLAMA_FLASH_ATTENTION' | Should -Be '1'
        }

        It "Should pin Ollama to loopback" {
            Get-NucleusUserEnvironmentVariable -Name 'OLLAMA_HOST' | Should -Be '127.0.0.1:11434'
        }

        It "Should compress the Ollama KV cache" {
            Get-NucleusUserEnvironmentVariable -Name 'OLLAMA_KV_CACHE_TYPE' | Should -Be 'q4_0'
        }

        It "Should set the Ollama default context length to 32k" {
            Get-NucleusUserEnvironmentVariable -Name 'OLLAMA_NUM_CTX' | Should -Be '32768'
        }
    }
}
