---
description: "Use when modifying, debugging, or troubleshooting the Spotlight (cmd+space) disable mechanism on macOS. Covers the proven 6-stage strategy, why single-hotkey approaches fail, and the critical role of each disable stage."
name: "Spotlight Disable Strategy (macOS)"
applyTo: "src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md, tests/integration/activation-deps-tests.nix, src/hosts/MacBook/defaults.nix"
---

# Spotlight Disable Strategy for macOS

## Problem

Spotlight (cmd+space) cannot be fully disabled by setting a single keyboard shortcut. macOS stores the binding across multiple symbolic-hotkey slots (61, 64, 65) depending on OS version, migration history, and hardware platform.

## 6-stage solution (all stages required)

The working solution comprises six interdependent stages, each handling a different layer of Spotlight control. Removing any single stage will cause Spotlight to re-enable or partially persist. This is a complete system — not a collection of independent tasks.

### Stage 1: Disable all three hotkey IDs (61, 64, 65)

Loop over symbolic-hotkey IDs 61, 64, 65 and write `enabled=false` to each via `defaults write`. All three IDs must be disabled because macOS uses different ID slots across versions (Mojave→Sequoia), profile migrations preserve old entries, and disabling only one ID still leaves Cmd+Space active.

**Implementation** (in `src/hosts/MacBook/activation.nix`):

```bash
spotlight_hotkeys="61 64 65"
for hotkey in $spotlight_hotkeys; do
  /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
    /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
      -dict-add "$hotkey" "<dict><key>enabled</key><false/></dict>"
done
```

### Stage 2: Invoke activateSettings -u immediately

Call `activateSettings -u` as the console user immediately after the hotkey writes. Without this, the disable applies only to the next login session and Cmd+Space still works until logout. It forces the loginwindow daemon to re-read hotkey settings immediately, making the disable user-visible in the current session. Must run as the console user (not root) because it operates on the user's session context.

**Implementation**:

```bash
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

### Stage 3: launchctl disable — prevent re-launch on reboot

Disable the `com.apple.Spotlight` launchd service. Even if hotkeys and indexing are disabled, the service can be re-enabled by system updates or manual intervention. `launchctl disable` removes it from the auto-start registry, preventing reboot-based restoration.

**Implementation**:

```bash
/bin/launchctl disable "gui/$console_uid/com.apple.Spotlight"
```

### Stage 4: launchctl bootout — stop running instance immediately

Boot out (immediately stop) the running `com.apple.Spotlight` service. `launchctl disable` prevents re-launch but does not stop an already-running process. `launchctl bootout` terminates it now, preventing any in-flight re-enable or listener activity.

**Implementation**:

```bash
/bin/launchctl bootout "gui/$console_uid/com.apple.Spotlight"
```

`bootout` may fail with a non-zero exit code if the service is already absent (e.g., a previous activation already stopped it). This is expected and safe; log it as a warning, not an error.

SIP nuance (macOS 15+): `launchctl bootout gui/<uid>/com.apple.Spotlight` can return `Operation not permitted while System Integrity Protection is engaged` even when `launchctl disable` and `mdutil -i off /` have already converged the effective state. Treat this as an expected classified warning (not a hard error), and avoid printing raw unclassified `launchctl` output directly in activation logs.

### Stage 5: mdutil -i off / — disable Spotlight indexing globally

Disable Spotlight indexing at the filesystem level for the root volume. Even if the launchd service is disabled, the indexing subsystem can persist. `mdutil -i off /` is enforced at the kernel/storage layer, so indexing stays off even if an admin or macOS update re-enables the service. Requires root privileges — must run in `system.activationScripts`, not `home.activation`.

**Implementation**:

```bash
/usr/bin/mdutil -i off /
```

### Stage 6: Remove cache directory `/.Spotlight-V100`

Delete the existing Spotlight index cache at `/.Spotlight-V100`. Without a pre-built cache, Spotlight must rebuild from scratch if re-enabled, making re-enable less convenient. Combined with `mdutil -i off`, this ensures no indexed data is available even if Spotlight is re-enabled.

**Implementation**:

```bash
if [ -d "/.Spotlight-V100" ]; then
  /bin/rm -rf "/.Spotlight-V100"
fi
```

## Why this must run in system.activationScripts (not home.activation)

The entire strategy must run in `system.activationScripts.postActivation.text` (as root via `darwin-rebuild switch`), not in `home.activation` (logged-in user context). Three operations require root privilege unavailable in user context even with `sudo`: (1) `mdutil -i off /`, (2) `launchctl bootout`, (3) `launchctl disable`.

## Testing and verification

After applying, verify:

1. **Hotkey IDs disabled** — `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 '"61"'` (all three IDs 61, 64, 65 should show `<false/>`).
2. **Spotlight indexing off** — `mdutil -s /` should report no indexing.
3. **Service disabled and stopped** — `launchctl list | grep Spotlight` should be empty.
4. **Cache removed** — `ls -la /.Spotlight-V100` should show "No such file or directory".
5. **User-visible test**: Press `cmd+space` in the active GUI session — Spotlight should not appear. If it still opens, the disable failed (revisit stages 1–2; `activateSettings -u` may not have succeeded).
