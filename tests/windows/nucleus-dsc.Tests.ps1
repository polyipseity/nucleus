# tests/windows/nucleus-dsc.Tests.ps1 — Pester tests for Windows DSC baseline validation.
#
# Verifies that Windows DSC resources (packages, registry, folders) are applied
# correctly and system state matches declarative intent.
#
# Run with: Invoke-Pester -Path tests/windows/nucleus-dsc.Tests.ps1 -Verbose
#
# Note: Requires admin privileges to check some registry paths and install status.

BeforeAll {
    # Silence progress messages during test execution.
    $ProgressPreference = 'SilentlyContinue'
}

Describe "Windows Package Installation" {
    <#
    .DESCRIPTION
    Verify that critical cross-host packages are installed via WinGet DSC.
    These tests check presence, not version, to avoid fragility on updates.
    #>

    Context "CLI Tools (Cross-Platform Parity)" {
        It "Should have zoxide installed (shell navigation)" {
            $pkg = winget list --exact -q "ajeetdsouza.zoxide" | Where-Object { $_ -like "*zoxide*" }
            $pkg | Should -Not -BeNullOrEmpty
        }

        It "Should have uv installed (Python project manager)" {
            $pkg = winget list --exact -q "astral-sh.uv" | Where-Object { $_ -like "*uv*" }
            $pkg | Should -Not -BeNullOrEmpty
        }

        It "Should have 7-Zip installed (archive handling)" {
            $pkg = winget list --exact -q "7zip.7zip" | Where-Object { $_ -like "*7-Zip*" }
            $pkg | Should -Not -BeNullOrEmpty
        }
    }

    Context "GUI Applications (Cross-Platform Parity)" {
        It "Should have Blender installed" {
            $pkg = winget list --exact -q "BlenderFoundation.Blender" | Where-Object { $_ -like "*Blender*" }
            $pkg | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Windows Security & Desktop Configuration" {
    <#
    .DESCRIPTION
    Verify that user-level registry settings enforce security invariants:
    - Screen saver is active and requires password
    - Wallpaper directory exists and is configured
    - Settings align with macOS/NixOS security posture (immediate lock).
    #>

    Context "Screen Saver Security (Security Invariant)" {
        It "Should have screen saver enabled" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $value = Get-ItemProperty -Path $regPath -Name ScreenSaveActive -ErrorAction SilentlyContinue
            $value.ScreenSaveActive | Should -Be "1"
        }

        It "Should require password on screen saver resume" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $value = Get-ItemProperty -Path $regPath -Name ScreenSaverIsSecure -ErrorAction SilentlyContinue
            $value.ScreenSaverIsSecure | Should -Be "1"
        }

        It "Should have aggressive 60-second idle timeout" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $value = Get-ItemProperty -Path $regPath -Name ScreenSaveTimeout -ErrorAction SilentlyContinue
            [int]$timeout = $value.ScreenSaveTimeout
            $timeout | Should -BeLessThanOrEqual 60
        }
    }

    Context "Wallpaper & Desktop Configuration" {
        It "Should have wallpaper folder created" {
            $wallpaperPath = [System.Environment]::ExpandEnvironmentVariables("%USERPROFILE%\Pictures\wallpapers")
            Test-Path -Path $wallpaperPath | Should -Be $true
        }

        It "Should have wallpaper registry entry configured" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $value = Get-ItemProperty -Path $regPath -Name Wallpaper -ErrorAction SilentlyContinue
            $value.Wallpaper | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Long Path Support (Windows-Specific Invariant)" {
    <#
    .DESCRIPTION
    Verify that Windows long path support is enabled at the system level.
    This prevents Nix/Git failures on deep directory trees (required for
    declarative system configuration management).
    #>

    It "Should have long path support enabled" {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
        $value = Get-ItemProperty -Path $regPath -Name LongPathsEnabled -ErrorAction SilentlyContinue
        $value.LongPathsEnabled | Should -Be 1
    }
}

Describe "Test-Driven Development Scaffolding" {
    <#
    .DESCRIPTION
    Basic smoke tests to ensure Pester framework integration is working.
    These always pass and serve as validation that the test suite can run.
    #>

    It "Should complete with Windows version information available" {
        $osInfo = [System.Environment]::OSVersion
        $osInfo.Platform | Should -Be "Win32NT"
    }

    It "Should have PowerShell 5.0 or higher" {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterThanOrEqual 5
    }
}
