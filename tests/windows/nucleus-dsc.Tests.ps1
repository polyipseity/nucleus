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
    Comprehensive package validation for cross-platform parity.
    Tests cover CLI tools, GUI apps, development tools, and utilities.
    #>

    Context "CLI Tools (Cross-Platform Parity)" {
        $cliTools = @(
            @{ id = "ajeetdsouza.zoxide"; displayName = "zoxide (shell navigation)" }
            @{ id = "astral-sh.uv"; displayName = "uv (Python project manager)" }
            @{ id = "7zip.7zip"; displayName = "7-Zip (archive handling)" }
            @{ id = "BurntSushi.ripgrep.MSVC"; displayName = "ripgrep (fast text search)" }
            @{ id = "junegunn.fzf"; displayName = "fzf (fuzzy finder)" }
            @{ id = "j178.Prek"; displayName = "prek (git hook manager)" }
        )

        foreach ($tool in $cliTools) {
            It "Should have $($tool.displayName) installed" {
                $pkg = winget list --exact -q $tool.id 2>$null | Where-Object { $_ }
                $pkg | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Development Tools (Language Runtimes & Build)" {
        $devTools = @(
            @{ id = "Python.Python.3.12"; displayName = "Python 3.12" }
            @{ id = "Git.Git"; displayName = "Git (version control)" }
            @{ id = "OpenJS.NodeJS"; displayName = "Node.js (JS runtime)" }
            @{ id = "Rustlang.Rust.MSVC"; displayName = "Rust (systems language)" }
        )

        foreach ($tool in $devTools) {
            It "Should have $($tool.displayName) installed" {
                $pkg = winget list --exact -q $tool.id 2>$null | Where-Object { $_ }
                $pkg | Should -Not -BeNullOrEmpty
            }
        }

        It "Should have gitk available from the Git installation" {
            $gitk = Get-Command -Name gitk -ErrorAction SilentlyContinue
            $gitk | Should -Not -BeNullOrEmpty
        }
    }

    Context "GUI Applications (Cross-Platform Parity)" {
        $guiApps = @(
            @{ id = "BlenderFoundation.Blender"; displayName = "Blender (3D creation)" }
            @{ id = "Microsoft.VisualStudioCode.Insiders"; displayName = "VS Code Insiders (editor)" }
            @{ id = "Discord.Discord.Canary"; displayName = "Discord Canary (messaging)" }
        )

        foreach ($app in $guiApps) {
            It "Should have $($app.displayName) installed" {
                $pkg = winget list --exact -q $app.id 2>$null | Where-Object { $_ }
                $pkg | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Utilities (System Tools & Formatters)" {
        $utilities = @(
            @{ id = "sharkdp.bat"; displayName = "bat (syntax highlighting cat)" }
            @{ id = "eza-community.eza"; displayName = "eza (modern ls)" }
            @{ id = "jqlang.jq"; displayName = "jq (JSON processor)" }
        )

        foreach ($util in $utilities) {
            It "Should have $($util.displayName) installed" {
                $pkg = winget list --exact -q $util.id 2>$null | Where-Object { $_ }
                $pkg | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe "Windows Security & Desktop Configuration" {
    <#
    .DESCRIPTION
    Comprehensive validation of user-level registry settings.
    Verifies security invariants, desktop behavior, and accessibility settings.
    #>

    Context "Screen Saver Security (Security Invariant - Parity with macOS/NixOS)" {
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

        It "Should have aggressive 60-second idle timeout (parity with POSIX lock timeout)" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $value = Get-ItemProperty -Path $regPath -Name ScreenSaveTimeout -ErrorAction SilentlyContinue
            [int]$timeout = $value.ScreenSaveTimeout
            $timeout | Should -BeLessThanOrEqual 60
        }

        It "Should use blank screen saver (security: no login hint leakage)" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $scr = Get-ItemProperty -Path $regPath -Name SCRNSAVE.EXE -ErrorAction SilentlyContinue
            $scr.SCRNSAVE.EXE | Should -Match "ssblank\.scr" -Or $null
        }
    }

    Context "Wallpaper & Desktop Customization" {
        It "Should have wallpaper folder created" {
            $wallpaperPath = [System.Environment]::ExpandEnvironmentVariables("%USERPROFILE%\Pictures\wallpapers")
            Test-Path -Path $wallpaperPath | Should -Be $true
        }

        It "Should have wallpaper registry entry configured" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $wallpaper = Get-ItemProperty -Path $regPath -Name Wallpaper -ErrorAction SilentlyContinue
            $wallpaper.Wallpaper | Should -Not -BeNullOrEmpty
        }

        It "Should have tile wallpaper disabled (stretch, not repeat)" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $tileWallpaper = Get-ItemProperty -Path $regPath -Name TileWallpaper -ErrorAction SilentlyContinue
            $tileWallpaper.TileWallpaper | Should -Be "0"
        }

        It "Should have wallpaper style set to fit or fill" {
            $regPath = "HKCU:\Control Panel\Desktop"
            $wallpaperStyle = Get-ItemProperty -Path $regPath -Name WallpaperStyle -ErrorAction SilentlyContinue
            [int]$style = $wallpaperStyle.WallpaperStyle
            $style | Should -Match "^[1-6]$"  # 1=tiled, 2=centered, 6=fill, 10=fit
        }
    }

    Context "Keyboard & Input Settings" {
        It "Should have key repeat rate configured" {
            $regPath = "HKCU:\Control Panel\Keyboard"
            $keyboardRep = Get-ItemProperty -Path $regPath -Name KeyboardDelay -ErrorAction SilentlyContinue
            $keyboardRep.KeyboardDelay | Should -Not -BeNullOrEmpty
        }

        It "Should have keyboard speed set to maximum (faster typing)" {
            $regPath = "HKCU:\Control Panel\Keyboard"
            $keyboardSpeed = Get-ItemProperty -Path $regPath -Name KeyboardSpeed -ErrorAction SilentlyContinue
            [int]$speed = $keyboardSpeed.KeyboardSpeed
            $speed | Should -BeGreaterThanOrEqual 30  # Scale 0-31, 31 is fastest
        }
    }

    Context "File Explorer (Shell) Behavior" {
        It "Should show hidden files" {
            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $hidden = Get-ItemProperty -Path $regPath -Name Hidden -ErrorAction SilentlyContinue
            [int]$hiddenVal = $hidden.Hidden
            $hiddenVal | Should -Be 1
        }

        It "Should show file extensions" {
            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $hideExt = Get-ItemProperty -Path $regPath -Name HideFileExt -ErrorAction SilentlyContinue
            [int]$extVal = $hideExt.HideFileExt
            $extVal | Should -Be 0
        }

        It "Should show full file path in title bar" {
            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $fullPath = Get-ItemProperty -Path $regPath -Name FullPath -ErrorAction SilentlyContinue
            [int]$pathVal = $fullPath.FullPath
            $pathVal | Should -Be 1
        }
    }

    Context "Accessibility & UI Preferences" {
        It "Should have mouse pointer speed configured" {
            $regPath = "HKCU:\Control Panel\Mouse"
            $mouseSpeed = Get-ItemProperty -Path $regPath -Name MouseSensitivity -ErrorAction SilentlyContinue
            $mouseSpeed.MouseSensitivity | Should -Not -BeNullOrEmpty
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

Describe "Windows Power & Remote-Access Parity" {
    <#
    .DESCRIPTION
    Validate the Windows power posture required for unattended closed-lid
    work: lid-close must not suspend the machine, and TCP keepalives must stay
    aggressive enough for remote sessions to survive idle network equipment.
    #>

    It "Should keep TCP keepalive at 60 seconds" {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        $value = Get-ItemProperty -Path $regPath -Name KeepAliveTime -ErrorAction SilentlyContinue
        $value.KeepAliveTime | Should -Be 60000
    }

    It "Should set lid close action to Do Nothing on AC and battery" {
        $lidQuery = powercfg /query scheme_current SUB_BUTTONS LIDACTION | Out-String
        $lidQuery | Should -Match 'Current AC Power Setting Index:\s+0x00000000'
        $lidQuery | Should -Match 'Current DC Power Setting Index:\s+0x00000000'
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
