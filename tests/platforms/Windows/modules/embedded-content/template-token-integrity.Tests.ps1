<#
.SYNOPSIS
    Verifies VM template token integrity: every __TOKEN__ placeholder in a VM
    template is replaced by its consumer (Invoke-VMSetup.ps1) and no legacy
    {{TOKEN}} syntax remains in templates.
.DESCRIPTION
    Static analysis tests (parse files, do not execute).  Guarantees the
    render-leftover invariant: after Invoke-VMSetup substitutes the render
    chain, no template placeholder survives in the written start script.  A
    template token missing from the render chain, or a render-chain token
    missing from every template, fails the suite.

    Templates covered:
    - src/vms/templates/start-windows.ps1 (12 tokens, Windows start script)
    - src/vms/templates/start-windows-host.sh (11 tokens, Git Bash/MSYS start script)
    - src/vms/templates/README.md (1 token, VM directory guide)
    - src/vms/Windows/Autounattend.xml (3 tokens, Windows guest unattended setup)
    - src/scripts/vms/start-android-vm.ps1 (7 tokens, Android QEMU start script)
    - src/vms/templates/stop-host.ps1 (2 tokens, host-kind stop script)

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/embedded-content/template-token-integrity.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..\")
  $TemplatesDir = Join-Path $RepoRoot "src\vms\templates"
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\platforms\Windows\modules\system\Invoke-VMSetup.ps1"

  # Resolves template paths through this closure so PSUseDeclaredVarsMoreThanAssignments
  # sees TemplatesDir read within the BeforeAll scriptblock (It blocks are sibling scopes).
  function Get-TemplatePath([string]$Name) {
    return Join-Path $TemplatesDir $Name
  }

  # start-android-vm.ps1 lives outside src/vms/templates; its path is resolved
  # inline in the Describe below (same pattern as Autounattend.xml) to keep
  # PSUseDeclaredVarsMoreThanAssignments quiet.

  function Get-UpperSnakeTokenList([string]$Path) {
    $content = Get-Content -Raw -Path $Path
    return @([regex]::Matches($content, '__[A-Z][A-Z_]*__') | ForEach-Object { $_.Value.Trim('_') } | Sort-Object -Unique)
  }

  # Tokens targeted by the .Replace('__X__', ...) render chains in Invoke-VMSetup.ps1.
  function Get-ReplaceChainTokenList {
    $content = Get-Content -Raw -Path $InvokeVMSetupPath
    return @([regex]::Matches($content, "\.Replace\('__[A-Z][A-Z_]*__'") | ForEach-Object { ($_.Value -replace "\.Replace\('", "" -replace "'", "").Trim('_') } | Sort-Object -Unique)
  }

  # Tokens targeted by the -replace '__X__', ... chains (README render).
  function Get-DashReplaceTokenList {
    $content = Get-Content -Raw -Path $InvokeVMSetupPath
    return @([regex]::Matches($content, "-replace '__[A-Z][A-Z_]*__'") | ForEach-Object { ($_.Value -replace "-replace '", "" -replace "'", "").Trim('_') } | Sort-Object -Unique)
  }

  # Tokens targeted by the sed -e "s|__X__|..." render chains in vm.sh
  # (POSIX-side start/stop helper templates).
  function Get-VmShSedChainTokenList {
    $vmSh = (Get-Content -Raw -Path (Join-Path $RepoRoot "scripts\vm.sh")) +
      (Get-Content -Raw -Path (Join-Path $RepoRoot "src\scripts\lib\vm.sh"))
    return @([regex]::Matches($vmSh, 's\|__[A-Z][A-Z_]*__\|') | ForEach-Object { ($_.Value -replace 's\|__', '' -replace '__\|', '').Trim('_') } | Sort-Object -Unique)
  }
}

Describe "start-windows.ps1 template token integrity" {
  It "declares exactly the 12 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-windows.ps1")
    ($templateTokens -join ",") | Should -Be "CPU,CPUS,DISK_PATH,DISPLAY_BACKEND,HOSTFWDS,MACHINE,QEMU_SYSTEM,RAM_BYTES,VGA,VIRTIOFS_ARGS,VM_DISPLAY,VM_ID"
  }

  It "every placeholder has a replacement in the Invoke-VMSetup render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-windows.ps1")
    $chainTokens = Get-ReplaceChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "start-windows-host.sh template token integrity" {
  It "declares exactly the 11 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-windows-host.sh")
    ($templateTokens -join ",") | Should -Be "CPU,CPUS,DISK_PATH,DISPLAY_BACKEND,HOSTFWDS,MACHINE,QEMU_SYSTEM,RAM_BYTES,VGA,VM_DISPLAY,VM_ID"
  }

  It "every placeholder has a replacement in the Invoke-VMSetup render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-windows-host.sh")
    $chainTokens = Get-ReplaceChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "start-host.ps1 template token integrity" {
  It "declares exactly the 4 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-host.ps1")
    ($templateTokens -join ",") | Should -Be "HOST_KIND,TART_SOFTNET_EXPOSE,VM_DIR,VM_DISPLAY,VM_ID"
  }

  It "every placeholder has a replacement in the vm.sh sed render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "start-host.ps1")
    $chainTokens = Get-VmShSedChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "stop-posix.sh template token integrity" {
  It "declares exactly the 3 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "stop-posix.sh")
    ($templateTokens -join ",") | Should -Be "HOST_KIND,VM_DISPLAY,VM_ID"
  }

  It "every placeholder has a replacement in the vm.sh sed render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "stop-posix.sh")
    $chainTokens = Get-VmShSedChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "stop-host.ps1 template token integrity" {
  It "declares exactly the 2 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "stop-host.ps1")
    ($templateTokens -join ",") | Should -Be "HOST_KIND,VM_ID"
  }

  It "every placeholder has a replacement in the vm.sh sed render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "stop-host.ps1")
    $chainTokens = Get-VmShSedChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "README.md template token integrity" {
  It "declares the directory-display __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Get-TemplatePath "README.md")
    @('VM_DIR_DISPLAY') | ForEach-Object {
      $_ | Should -BeIn $templateTokens
    }
  }

  It "directory-display placeholders have replacements in vm.sh and Invoke-VMSetup" {
    $vmSh = (Get-Content -Raw -Path (Join-Path $RepoRoot "scripts\vm.sh")) +
      (Get-Content -Raw -Path (Join-Path $RepoRoot "src\scripts\lib\vm.sh"))
    $vmSh | Should -Match ([regex]::Escape('__VM_DIR_DISPLAY__'))
    (Get-DashReplaceTokenList) | Should -Contain 'VM_DIR_DISPLAY'
  }
}

Describe "Autounattend.xml template token integrity" {
  It "declares exactly the 3 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\vms\windows\Autounattend.xml")
    ($templateTokens -join ",") | Should -Be "GUEST_HOSTNAME,NUCLEUS_GUEST_PASSWORD,NUCLEUS_GUEST_USERNAME"
  }

  It "every placeholder has a replacement in the Invoke-VMSetup render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\vms\windows\Autounattend.xml")
    $chainTokens = Get-ReplaceChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "start-android-vm.ps1 template token integrity" {
  It "declares exactly the 7 expected __TOKEN__ placeholders" {
    $templateTokens = Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\scripts\vms\start-android-vm.ps1")
    ($templateTokens -join ",") | Should -Be "ANDROID_CPU_COUNT,ANDROID_GSI_IMAGE,ANDROID_RAM_BYTES,ANDROID_SYSTEM_IMAGE,ANDROID_USERDATA_IMAGE,HOSTFWDS"
  }

  It "every placeholder has a replacement in the vm.sh sed render chain" {
    $templateTokens = Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\scripts\vms\start-android-vm.ps1")
    $chainTokens = Get-VmShSedChainTokenList
    $missing = @($templateTokens | Where-Object { $_ -notin $chainTokens })
    $missing | Should -BeNullOrEmpty
  }
}

Describe "Render chain has no dangling replacements" {
  It "every render-chain token exists in at least one template" {
    $knownTokens = @(
      (Get-UpperSnakeTokenList (Get-TemplatePath "start-windows.ps1")) +
      (Get-UpperSnakeTokenList (Get-TemplatePath "start-windows-host.sh")) +
      (Get-UpperSnakeTokenList (Get-TemplatePath "README.md")) +
      (Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\vms\windows\Autounattend.xml")) +
      (Get-UpperSnakeTokenList (Join-Path $RepoRoot "src\scripts\vms\start-android-vm.ps1")) +
      (Get-UpperSnakeTokenList (Get-TemplatePath "stop-host.ps1"))
    ) | Sort-Object -Unique
    $dangling = @((Get-ReplaceChainTokenList) + (Get-DashReplaceTokenList) | Where-Object { $_ -notin $knownTokens } | Sort-Object -Unique)
    $dangling | Should -BeNullOrEmpty
  }
}

Describe "No legacy {{TOKEN}} syntax in VM templates" {
  It "templates contain no {{ placeholders" {
    foreach ($relativePath in @(
        "src\vms\templates\start-windows.ps1",
        "src\vms\templates\start-windows-host.sh",
        "src\vms\templates\start-host.ps1",
        "src\vms\templates\stop-posix.sh",
        "src\vms\templates\stop-host.ps1",
        "src\vms\templates\README.md",
        "src\vms\windows\Autounattend.xml"
      )) {
      $content = Get-Content -Raw -Path (Join-Path $RepoRoot $relativePath)
      $content | Should -Not -Match '\{\{[A-Za-z_]'
    }
  }
}
