function Sync-UserPath {
  <#
  .SYNOPSIS
    Converges a managed user-scope PATH persistence block in the Machine-scope registry.

  .DESCRIPTION
    Reads the current Machine-scope PATH from HKLM, strips any previously-managed
    nucleus entries, prepends the three user-scope package manager binary directories
    (.bun\bin, .cargo\bin, .local\bin) as %USERPROFILE%-prefixed REG_EXPAND_SZ,
    broadcasts WM_SETTINGCHANGE so running processes pick up the change, and cleans
    up stale User-scope entries from the old DSC-based approach.

    Elevation is required (admin privileges to write to HKLM). The caller
    (apply.ps1) self-elevates before this function runs.

    Canonical PATH component source: src/modules/lib/managed-paths.nix (pathComponents).

  .PARAMETER Enabled
    Whether managed PATH convergence should be enforced. Mandatory: caller must
    explicitly choose true (apply) or false (cleanup).

    When true: prepends nucleus-managed directories to Machine-scope PATH.
    When false: removes nucleus-managed directories from Machine-scope PATH
    (if any remain).

  .EXAMPLE
    Sync-UserPath -Enabled:$true

  .EXAMPLE
    Sync-UserPath -Enabled:$false

  .NOTES
    Environment variables: reads/writes [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Exit codes: 0 on success; non-zero on failure

    Elevation: required (HKLM write). Handled by apply.ps1 self-elevation.

    Why Machine scope with %USERPROFILE%:
      - %USERPROFILE% is stored literally as REG_EXPAND_SZ in the registry
        and resolved per-user by CreateEnvironmentBlock at process creation time.
      - Same pattern as the official bun installer.
      - Our entries in Machine scope come before all User-scope entries in
        the CreateEnvironmentBlock merge order [Machine];[User].
      - Non-interactive sessions (services without LoadUserProfile) resolve
        %USERPROFILE% to system profile dirs — acceptable since our tools
        (bun, cargo, uv) are interactive-only.
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # Canonical source: ManagedPaths.ps1 → src/modules/lib/managed-paths.nix (pathComponents).
  $nucleusPrependDirs = $nucleusPrependRegistry
  $nucleusAppendDirs = $nucleusAppendRegistry
  $nucleusDirs = $nucleusPrependDirs + $nucleusAppendDirs # dedup SET (membership check), NOT a PATH ordering

  # ── Machine PATH (HKLM) ──────────────────────────────────────────
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  $currentMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $currentMachinePath ??= ''

  # Strip existing nucleus entries from Machine PATH (avoid duplication on re-apply).
  $cleanedMachine = ($currentMachinePath -split ';') | Where-Object {
    $_ -and ($nucleusDirs -notcontains $_)
  }

  if ($Enabled) {
    $newMachinePath = ($nucleusPrependDirs + $cleanedMachine + $nucleusAppendDirs) -join ';'
  } else {
    $newMachinePath = $cleanedMachine -join ';'
  }

  Set-ItemProperty -Path $regPath -Name 'Path' -Value $newMachinePath -Type ExpandString

  # ── Clean up stale User-scope entries from old DSC approach ────
  $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $currentUserPath ??= ''
  $cleanedUser = ($currentUserPath -split ';') | Where-Object {
    $_ -and ($nucleusDirs -notcontains $_)
  }
  $newUserPath = $cleanedUser -join ';'
  [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')

  # ── Broadcast WM_SETTINGCHANGE ──────────────────────────────────
  # Notify running processes (including Explorer) that environment has changed
  # so they pick up the new PATH without a restart.
  $HWND_BROADCAST = 0xffff
  $WM_SETTINGCHANGE = 0x001a
  # check-suppress:embedded-content: exception 3 (C# interop) -- P/Invoke classes stay inline up to 25 lines
  $sendMessageTimeoutSource = @'
using System;
using System.Runtime.InteropServices;
public static class User32 {
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult
  );
}
'@
  Add-Type -TypeDefinition $sendMessageTimeoutSource -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: type may already be loaded; Add-Type errors on redefinition so silently continue
  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional; SendMessageTimeout return value discarded, HWND broadcast is fire-and-forget
  $null = [User32]::SendMessageTimeout(
    [IntPtr]$HWND_BROADCAST,
    $WM_SETTINGCHANGE,
    [UIntPtr]::Zero,
    'Environment',
    2,        # SMTO_ABORTIFHUNG
    5000,
    [UIntPtr]::Zero
  )
}
