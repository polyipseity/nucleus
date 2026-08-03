# tests/integration/lid-closed-agent-runtime-tests.nix — Verify lid-closed agent runtime posture.
#
# Guards the cross-host contract for unattended work with the lid shut:
# - macOS keeps its no-idle-sleep posture and documents the clamshell limit
# - NixOS ignores lid-close events on every power source
# - Windows power parity manages lid-close action explicitly
# - CI executes this suite so regressions fail fast

let
  lib = import <nixpkgs/lib>;
  ciWorkflowText = builtins.readFile ../../.github/workflows/ci.yml;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  nixosDesktopText = builtins.readFile ../../src/hosts/NixOS/desktop.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsPowerPolicyText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-PowerPolicy.ps1;
  batteryPolicyText = builtins.readFile ../../src/scripts/hosts/MacBook/macos-configure-battery-policy.sh;

  inherit (import ../lib.nix) assert';

  test_macos_keeps_remote_session_pmset_posture =
    assert'
      (
        (lib.hasInfix "apply_pmset -a standby 1 ttyskeepawake 1 hibernatemode 3 networkoversleep 0 tcpkeepalive 1 powernap 1 lidwake 1" batteryPolicyText)
        && (lib.hasInfix "apply_pmset -c displaysleep 1 sleep 0 disksleep 0 womp 1" batteryPolicyText)
        && (lib.hasInfix "apply_pmset -b displaysleep 1 sleep 0 disksleep 0 womp 1" batteryPolicyText)
        && (lib.hasInfix "macos-configure-headless-display" macosText)
        && (lib.hasInfix "betterdisplay-heartbeat" macosText)
      )
      "macOS must keep the no-idle-sleep pmset posture and BetterDisplay heartbeat for closed-lid remote work";

  test_macos_documents_clamshell_limit = assert' (
    (lib.hasInfix "HeadlessDisplay" macosText) && (lib.hasInfix "clamshell" macosText)
  ) "macos.nix must document the HeadlessDisplay fallback for closed-lid remote work";

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

  test_ci_runs_this_suite = assert' (lib.hasInfix "nix run ./src#test -- --no-fail-fast" ciWorkflowText) "CI must execute the Nix test suite (dynamic discovery) so lid-closed runtime tests run";

  allTests = [
    test_macos_keeps_remote_session_pmset_posture
    test_macos_documents_clamshell_limit
    test_nixos_ignores_lid_switch_on_all_power_sources
    test_windows_power_policy_manages_lid_action
    test_windows_apply_executes_power_policy
    test_ci_runs_this_suite
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} lid-closed agent runtime tests passed";
}
