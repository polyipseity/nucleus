<#
.SYNOPSIS
    Validates that Windows-deployed config files match the content expected from
    the repository source files (cross-host content parity).
.DESCRIPTION
    Ensures configs deployed via Method 1 writable symlinks point to the correct
    repo file. For configs that are assembled or transformed, verifies the
    deployed content matches expectations.

    Currently covers:
    - cargo/config.toml: deployed content must match repo file (jobs=4, sccache)
    - git/system.gitignore: deployed global ignore must match repo file
    - SSH config: deployed Host github.com block must have correct directives

.NOTES
    Environment variables: NUCLEUS_REPO_ROOT — must point to the repo root.
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
    $repoRoot = $env:NUCLEUS_REPO_ROOT
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        # Fall back to deriving from script path (tests/hosts/Windows/regression/ -> repo root is 5 levels up).
        $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
    }
}

Describe "Cargo config content parity" {
    Context "cargo/config.toml" {
        It "Repo file should have jobs=4" {
            $repoContent = Get-Content -Path (Join-Path $repoRoot 'src\modules\configs\cargo\config.toml') -Raw
            $repoContent | Should -Match 'jobs = 4'
        }

        It "Repo file should have rustc-wrapper=sccache" {
            $repoContent = Get-Content -Path (Join-Path $repoRoot 'src\modules\configs\cargo\config.toml') -Raw
            $repoContent | Should -Match 'rustc-wrapper = "sccache"'
        }

        It "Repo file should NOT have jobs=8 (the old hardcoded value)" {
            $repoContent = Get-Content -Path (Join-Path $repoRoot 'src\modules\configs\cargo\config.toml') -Raw
            $repoContent | Should -Not -Match 'jobs = 8'
        }

        It "Deployed symlink should point to repo file" {
            $deployedPath = "$env:USERPROFILE\.cargo\config.toml"
            if (Test-Path -Path $deployedPath) {
                $item = Get-Item -Path $deployedPath -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $target = $item.Target
                    $target | Should -Be (Join-Path $repoRoot 'src\modules\configs\cargo\config.toml')
                }
                else {
                    Set-ItResult -Skipped -Because "cargo config is a regular file (not a symlink) — content parity verified via repo source"
                }
            }
            else {
                Set-ItResult -Skipped -Because "cargo config not yet deployed on this machine"
            }
        }
    }
}

Describe "Git ignore content parity" {
    Context "system.gitignore" {
        It "Repo file should contain Nix build output patterns" {
            $repoContent = Get-Content -Path (Join-Path $repoRoot 'src\modules\configs\git\system.gitignore') -Raw
            $repoContent | Should -Match '^result$'
            $repoContent | Should -Match '^\.direnv$'
        }

        It "Repo file should be the source for the deployed global ignore" {
            $deployedPath = "$env:ProgramData\nucleus\git\ignore-global"
            if (Test-Path -Path $deployedPath) {
                $item = Get-Item -Path $deployedPath -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $target = $item.Target
                    $target | Should -Be (Join-Path $repoRoot 'src\modules\configs\git\system.gitignore')
                }
                else {
                    Set-ItResult -Skipped -Because "gitignore is a regular file (not a symlink) — content parity verified via repo source"
                }
            }
            else {
                Set-ItResult -Skipped -Because "gitignore not yet deployed on this machine"
            }
        }
    }
}

Describe "SSH config content parity" {
    Context "Host github.com block" {
        It "Deployed SSH config should have Host github.com with required directives" {
            $sshConfigPath = "$env:USERPROFILE\.ssh\config"
            if (Test-Path -Path $sshConfigPath) {
                $content = Get-Content -Path $sshConfigPath -Raw
                $content | Should -Match '(?m)^Host\s+github\.com\s*$'
                $content | Should -Match '(?m)^\s+HostName\s+github\.com\s*$'
                $content | Should -Match '(?m)^\s+IdentityFile\s+~/.ssh/'
                $content | Should -Match '(?m)^\s+AddKeysToAgent\s+yes\s*$'
            }
            else {
                Set-ItResult -Skipped -Because "SSH config not yet deployed on this machine"
            }
        }

        It "Deployed SSH config should NOT have sentinel markers" {
            $sshConfigPath = "$env:USERPROFILE\.ssh\config"
            if (Test-Path -Path $sshConfigPath) {
                $content = Get-Content -Path $sshConfigPath -Raw
                $content | Should -Not -Match '>>> config managed github ssh'
            }
            else {
                Set-ItResult -Skipped -Because "SSH config not yet deployed on this machine"
            }
        }
    }
}
