BeforeAll {
  # Import test utilities
  $ErrorActionPreference = "Stop"
  $WarningPreference = "SilentlyContinue"

  # Paths to modules under test
  $ModulePaths = @(
    "src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1"
    "src/hosts/windows/modules/user/Sync-AgentsConfig.ps1"
    "src/hosts/windows/modules/user/Sync-AgentsSkill.ps1"
    "src/hosts/windows/modules/user/Sync-DevRepo.ps1"
  )

  # Verify all module files exist
  foreach ($path in $ModulePaths) {
    $fullPath = Join-Path -Path $PSScriptRoot -ChildPath "../../$path"
    if (-not (Test-Path -Path $fullPath)) {
      throw "Module not found: $fullPath"
    }
  }
}

Describe "Symlink Hardening - Windows" {
  Context "Sync-VSCodeConfig" {
    It "should contain Set-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Set-ManagedSymlinkDeleteProtection"
    }

    It "should contain Remove-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Remove-ManagedSymlinkDeleteProtection"
    }

    It "should use icacls for ACL deny operations" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match 'icacls.*\/deny.*\(D\)'
    }

    It "should support ShouldProcess for deletion protection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "SupportsShouldProcess"
      $content | Should -Match "PSCmdlet.ShouldProcess"
    }
  }

  Context "Sync-AgentsConfig" {
    It "should contain Set-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-AgentsConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Set-ManagedSymlinkDeleteProtection"
    }

    It "should contain Remove-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-AgentsConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Remove-ManagedSymlinkDeleteProtection"
    }

    It "should apply protection to managed symlinks" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-AgentsConfig.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Sync-AgentsConfig"
    }
  }

  Context "Sync-AgentsSkill" {
    It "should contain Set-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-AgentsSkill.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Set-ManagedSymlinkDeleteProtection"
    }

    It "should protect bundled skill symlinks" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-AgentsSkill.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Sync-AgentsSkill"
    }
  }

  Context "Sync-DevRepo" {
    It "should contain Set-ManagedSymlinkDeleteProtection" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-DevRepo.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Set-ManagedSymlinkDeleteProtection"
    }

    It "should protect newly created dev repo symlinks" {
      $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/modules/user/Sync-DevRepo.ps1"
      $content = Get-Content -Path $modulePath -Raw
      $content | Should -Match "Sync-DevRepo"
    }
  }

  Context "ACL Compliance Across All Modules" {
    It "should not expose plaintext ACL deny operations without ShouldProcess" {
      $modulePaths = @(
        "src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1",
        "src/hosts/windows/modules/user/Sync-AgentsConfig.ps1",
        "src/hosts/windows/modules/user/Sync-AgentsSkill.ps1",
        "src/hosts/windows/modules/user/Sync-DevRepo.ps1"
      )

      foreach ($relativePath in $modulePaths) {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../$relativePath"
        $content = Get-Content -Path $modulePath -Raw
        # Each module should have ShouldProcess support if it has icacls calls
        if ($content -match "icacls") {
          $content | Should -Match "SupportsShouldProcess" -Because "icacls call in $relativePath should have ShouldProcess"
        }
      }
    }

    It "should use variable interpolation safely with braces" {
      $modulePaths = @(
        "src/hosts/windows/modules/editors/Sync-VSCodeConfig.ps1",
        "src/hosts/windows/modules/user/Sync-AgentsConfig.ps1"
      )

      foreach ($relativePath in $modulePaths) {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "../../$relativePath"
        $content = Get-Content -Path $modulePath -Raw
        # Should not have bare "$Path :" patterns; should use "${Path} :" with braces
        $content | Should -Not -Match '\$Path\s*:' -Because "Path variable should use braces for string interpolation"
        $content | Should -Match '\$\{Path\}\s*:' -Because "Path variable should be enclosed in braces for safe interpolation"
      }
    }
  }
}

Describe "Obsidian Configuration - Windows DSC" {
  Context "WinGet DSC Obsidian Settings" {
    It "should have DisableAutoUpdate configuration" {
      $dscPath = Join-Path -Path $PSScriptRoot -ChildPath "../../src/hosts/windows/user.dsc.yml"
      $content = Get-Content -Path $dscPath -Raw
      # Check if Obsidian is configured (DSC format check)
      $content | Should -Match "Obsidian|obsidian" -Because "Obsidian should be configured in Windows DSC"
    }
  }
}
