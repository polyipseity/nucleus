# tests/nix/lid-closed-agent-runtime-tests.nix — Verify lid-closed agent runtime posture.
#
# Guards the cross-host contract for unattended work with the lid shut:
# - macOS keeps its no-idle-sleep posture and documents the clamshell limit
# - NixOS ignores lid-close events on every power source
# - Windows power parity manages lid-close action explicitly
# - CI executes this suite so regressions fail fast

{
  lib ? import <nixpkgs/lib>,
}:
let
  ciWorkflowText = builtins.readFile ../../.github/workflows/ci.yml;
  macManualText = builtins.readFile ../../src/hosts/macbook/MANUAL.md;
  macbookActivationText = builtins.readFile ../../src/hosts/macbook/activation.nix;
  nixosDesktopText = builtins.readFile ../../src/hosts/nixos/desktop.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/windows/apply.ps1;
  windowsPowerPolicyText = builtins.readFile ../../src/hosts/windows/modules/system/Sync-PowerPolicy.ps1;

  assert' = cond: msg: if !cond then throw msg else null;

  test_macos_keeps_remote_session_pmset_posture =
    assert'
      (
        (lib.hasInfix "apply_pmset -a standby 1 ttyskeepawake 1 hibernatemode 3 networkoversleep 0 tcpkeepalive 1 powernap 1 lidwake 1" macbookActivationText)
        && (lib.hasInfix "apply_pmset -c displaysleep 1 sleep 0 disksleep 0 womp 1" macbookActivationText)
        && (lib.hasInfix "apply_pmset -b displaysleep 1 sleep 0 disksleep 0 womp 1" macbookActivationText)
        && (lib.hasInfix "ensureHeadlessDisplay" macbookActivationText)
        && (lib.hasInfix "betterdisplay-heartbeat" macbookActivationText)
      )
      "macOS must keep the no-idle-sleep pmset posture and BetterDisplay heartbeat for closed-lid remote work";

  test_macos_manual_documents_clamshell_limit = assert' (
    (lib.hasInfix "Closed-lid agent work: keep the Mac on AC power" macManualText)
    && (lib.hasInfix "closing a Mac laptop display puts it to sleep" macManualText)
    && (lib.hasInfix "HeadlessDisplay" macManualText)
  ) "macOS manual must document the AC-power clamshell requirement and HeadlessDisplay fallback";

  test_nixos_ignores_lid_switch_on_all_power_sources = assert' (
    (lib.hasInfix "HandleLidSwitch = \"ignore\";" nixosDesktopText)
    && (lib.hasInfix "HandleLidSwitchDocked = \"ignore\";" nixosDesktopText)
    && (lib.hasInfix "HandleLidSwitchExternalPower = \"ignore\";" nixosDesktopText)
  ) "NixOS must ignore lid-close events on battery, docked, and external-power paths";

  test_windows_power_policy_manages_lid_action =
    assert'
      (
        (lib.hasInfix "LIDACTION" windowsPowerPolicyText)
        && (lib.hasInfix "/setacvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0'" windowsPowerPolicyText)
        && (lib.hasInfix "/setdcvalueindex', $activeSchemeGuid, $lidActionSubgroup, $lidActionSetting, '0'" windowsPowerPolicyText)
        && (lib.hasInfix "KeepAliveTime' -Value 60000" windowsPowerPolicyText)
      )
      "Windows power policy must set lid close action to Do Nothing and keep TCP keepalive at 60 seconds";

  test_windows_apply_executes_power_policy = assert' (
    (lib.hasInfix "Sync-PowerPolicy.ps1" windowsApplyText)
    && (lib.hasInfix "Sync-PowerPolicy -Enabled:$EnablePowerParity" windowsApplyText)
  ) "Windows apply.ps1 must load and execute Sync-PowerPolicy for lid-close parity";

  test_ci_runs_this_suite = assert' (lib.hasInfix "tests/nix/lid-closed-agent-runtime-tests.nix" ciWorkflowText) "CI must execute the lid-closed agent runtime tests";

  allTests = [
    test_macos_keeps_remote_session_pmset_posture
    test_macos_manual_documents_clamshell_limit
    test_nixos_ignores_lid_switch_on_all_power_sources
    test_windows_power_policy_manages_lid_action
    test_windows_apply_executes_power_policy
    test_ci_runs_this_suite
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} lid-closed agent runtime tests passed";
  testNames = [
    "1: macOS keeps remote-session pmset posture"
    "2: macOS manual documents clamshell limit"
    "3: NixOS ignores lid switch on all power sources"
    "4: Windows power policy manages lid action"
    "5: Windows apply executes power policy"
    "6: CI executes lid-closed runtime tests"
  ];
}
