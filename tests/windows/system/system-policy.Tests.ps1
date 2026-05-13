# tests/windows/system/system-policy.Tests.ps1 — Pester coverage for
# machine-scoped Windows policy and parity invariants.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\helpers\WindowsTestHelpers.ps1')
}

Describe "Windows System Policy Parity" {
    Context "Security and remote access invariants" {
        It "Should enable long path support" {
            Get-NucleusRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' | Should -Be 1
        }

        It "Should allow inbound Remote Desktop connections" {
            Get-NucleusRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' | Should -Be 0
        }

        It "Should require Network Level Authentication for RDP" {
            Get-NucleusRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' | Should -Be 1
        }

        It "Should keep all Windows Firewall profiles enabled" {
            $firewallProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
            $firewallProfiles | Should -Not -BeNullOrEmpty
            foreach ($firewallProfile in $firewallProfiles) {
                $firewallProfile.Enabled | Should -BeTrue
            }
        }
    }

    Context "Power and network posture" {
        It "Should keep TCP keepalive at 60 seconds" {
            Get-NucleusRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'KeepAliveTime' | Should -Be 60000
        }

        It "Should set lid close action to Do Nothing on AC and battery" {
            $lidQuery = powercfg /query scheme_current SUB_BUTTONS LIDACTION | Out-String
            $lidQuery | Should -Match 'Current AC Power Setting Index:\s+0x00000000'
            $lidQuery | Should -Match 'Current DC Power Setting Index:\s+0x00000000'
        }
    }

    Context "Managed font substitutions" {
        It "Should substitute Courier New with JetBrains Mono" {
            Get-NucleusRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' -Name 'Courier New' | Should -Be 'JetBrains Mono'
        }

        It "Should substitute Helvetica with Inter" {
            Get-NucleusRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' -Name 'Helvetica' | Should -Be 'Inter'
        }

        It "Should substitute Times New Roman with Source Serif 4" {
            Get-NucleusRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' -Name 'Times New Roman' | Should -Be 'Source Serif 4'
        }
    }
}
