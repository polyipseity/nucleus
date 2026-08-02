<#
.SYNOPSIS
    Pester coverage for the managed per-user Git baseline on Windows.
.DESCRIPTION
    Validates managed fetch, pull and push defaults (branch pruning, tag
    retention, fast-forward pull, auto-setup remote, tag-follow) and cross-host
    Git parity defaults. Signing and symlink keys (commit.gpgsign,
    tag.gpgsign, core.symlinks) are asserted at system scope via the
    Windows.gitconfig symlink; core.autocrlf and user.useConfigOnly stay
    per-user.
.NOTES
    Environment variables: USERPROFILE (resolved to locate .gitconfig)
    Exit codes: 0 on success; 1 on failure
#>

$script:gitConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath '.gitconfig'
$script:repoRoot = $env:NUCLEUS_REPO_ROOT
if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
    # Fall back to deriving from script path (tests/hosts/Windows/configuration/ -> repo root is 5 levels up).
    $script:repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
}

Describe "Windows Git Configuration Parity" {
    Context "Managed user-scope symlinks" {
        It "User gitconfig should be a symlink to the repo Windows.gitconfig" {
            if (Test-Path -Path $script:gitConfigPath) {
                $item = Get-Item -Path $script:gitConfigPath -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $item.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\git\Windows.gitconfig')
                }
                else {
                    Set-ItResult -Skipped -Because "user gitconfig is a regular file (not a symlink) — content parity verified via repo source"
                }
            }
            else {
                Set-ItResult -Skipped -Because "user gitconfig not yet deployed on this machine"
            }
        }

        It "User ignore should be a symlink to the repo Windows.gitignore" {
            $userIgnorePath = Join-Path -Path $env:USERPROFILE -ChildPath '.config\git\ignore'
            if (Test-Path -Path $userIgnorePath) {
                $item = Get-Item -Path $userIgnorePath -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $item.Target | Should -Be (Join-Path $script:repoRoot 'src\users\default\git\Windows.gitignore')
                }
                else {
                    Set-ItResult -Skipped -Because "user ignore is a regular file (not a symlink) — content parity verified via repo source"
                }
            }
            else {
                Set-ItResult -Skipped -Because "user ignore not yet deployed on this machine"
            }
        }
    }

    Context "Managed fetch, pull and push defaults" {
        It "Should prune remote-tracking branches on fetch" {
            git config --file $script:gitConfigPath --get fetch.prune | Should -Be 'true'
        }

        It "Should not overwrite local tags on fetch" {
            git config --file $script:gitConfigPath --get fetch.pruneTags | Should -Be 'false'
        }

        It "Should fast-forward pull when possible" {
            git config --file $script:gitConfigPath --get pull.ff | Should -Be 'true'
        }

        It "Should merge rather than rebase on pull" {
            git config --file $script:gitConfigPath --get pull.rebase | Should -Be 'false'
        }

        It "Should auto-setup remote on push" {
            git config --file $script:gitConfigPath --get push.autoSetupRemote | Should -Be 'true'
        }

        It "Should push related tags with branch pushes" {
            git config --file $script:gitConfigPath --get push.followTags | Should -Be 'true'
        }
    }

    Context "Git template boilerplate suppression" {
        It "Should set init.templateDir to empty template directory" {
            git config --file $script:gitConfigPath --get init.templateDir | Should -Be '~/.config/git/empty_template'
        }
    }

    Context "System-scope cross-host Git parity defaults" {
        It "Should symlink Git system config to the repo Windows.gitconfig" {
            # check-suppress:suppression_doc: probe -- git may not be installed; skip handles absence.
            $gitExecutable = Get-Command -Name 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
            if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
                Set-ItResult -Skipped -Because "git not installed on this machine"
            }
            else {
                $installRoot = (Get-ItemProperty -Path 'HKLM:\Software\GitForWindows' -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
                $systemConfigPath = Join-Path $installRoot 'etc\gitconfig'
                if (Test-Path -Path $systemConfigPath) {
                    $item = Get-Item -Path $systemConfigPath -Force
                    [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -BeTrue
                    $item.Target | Should -Be (Join-Path $script:repoRoot 'src\modules\configs\git\Windows.gitconfig')
                }
                else {
                    Set-ItResult -Skipped -Because "Git system config not yet deployed on this machine"
                }
            }
        }

        It "Should enable signed commits at system scope" {
            git config --system --get commit.gpgsign | Should -Be 'true'
        }

        It "Should enable signed tags at system scope" {
            git config --system --get tag.gpgsign | Should -Be 'true'
        }

        It "Should keep symlink support enabled at system scope" {
            git config --system --get core.symlinks | Should -Be 'true'
        }

        It "Should NOT duplicate signing/symlink defaults per-user" {
            git config --file $script:gitConfigPath --get commit.gpgsign | Should -BeNullOrEmpty
            git config --file $script:gitConfigPath --get tag.gpgsign | Should -BeNullOrEmpty
            git config --file $script:gitConfigPath --get core.symlinks | Should -BeNullOrEmpty
        }
    }

    Context "Existing cross-host Git parity defaults" {
        It "Should keep core.autocrlf enabled on Windows" {
            git config --file $script:gitConfigPath --get core.autocrlf | Should -Be 'true'
        }

        It "Should require explicit user identity config" {
            git config --file $script:gitConfigPath --get user.useConfigOnly | Should -Be 'true'
        }
    }
}
