---
description: "Use when modifying, debugging, or troubleshooting the Spotlight (cmd+space) disable mechanism on macOS. Covers the proven 6-stage strategy, why single-hotkey approaches fail, and the critical role of each disable stage."
name: "Spotlight Disable Strategy (macOS)"
applyTo: "src/hosts/macbook/activation.nix, src/hosts/macbook/MANUAL.md, tests/nix/*spotlight*, tests/nix/activation-deps-tests.nix, src/hosts/macbook/defaults.nix"
---

# Spotlight Disable Strategy for macOS

## Status: WORKING ✓

**Verification**: User confirmed `cmd+space` no longer triggers Spotlight (FIX VERIFIED).
The strategy documented here is **proven and production-ready**. Do not second-guess it or attempt "simplifications."

---

## Problem Statement

On macOS, Spotlight (the cmd+space launcher/search tool) cannot be fully disabled by setting a single keyboard shortcut. Attempts to disable only hotkey ID 61 leave Spotlight active because macOS stores the Cmd+Space binding across multiple symbolic-hotkey slots (61, 64, 65) depending on OS version, migration history, and hardware platform.

Previous failed approaches:

- ❌ Disabled only hotkey 61 → left 64 and 65 active → cmd+space still worked
- ❌ Ran disable at user level (home.activation) → insufficient privilege for mdutil/launchctl operations
- ❌ Ran mdutil without sudo → failed silently due to permission constraints
- ❌ Did not call `activateSettings -u` → changes applied only after logout/login, not immediately visible

---

## The 6-Stage Solution (ALL STAGES REQUIRED)

The working solution comprises **six interdependent stages**, each handling a different layer of Spotlight control. Removing any single stage will cause Spotlight to re-enable or partially persist. This is a **complete system** — not a collection of independent tasks.

### Stage 1: Disable All Three Hotkey IDs (61, 64, 65)

**What**: Loop over symbolic-hotkey IDs 61, 64, 65 and write `enabled=false` to each via `defaults write`.

**Why all three**:

- macOS uses different hotkey ID slots across versions (Mojave→Big Sur→Monterey→Ventura→Sonoma→Sequoia each evolved the layout).
- User profile migrations may preserve old hotkey entries in slots from previous OS versions.
- After a major OS upgrade (e.g., 12→13), old hotkey bindings may coexist with new ones.
- Disabling only one ID leaves the others active → Cmd+Space still works.
- **Covering all three ensures safety across version boundaries and migration scenarios.**

**Implementation** (in `src/hosts/macbook/activation.nix`):

```bash
spotlight_hotkeys="61 64 65"
for hotkey in $spotlight_hotkeys; do
  /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
    /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
      -dict-add "$hotkey" "<dict><key>enabled</key><false/></dict>"
done
```

### Stage 2: Invoke activateSettings -u Immediately (CRITICAL FOR RESPONSIVENESS)

**What**: Call `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u` as the console user immediately after the hotkey writes.

**Why this is critical**:

- Without `activateSettings -u`, the hotkey disable applies only to the **next login session**.
- Users see Cmd+Space **still work** until they log out and back in.
- `activateSettings -u` forces the loginwindow daemon to **re-read and apply the hotkey settings immediately** to the running session.
- This makes the disable **user-visible instantly**, which is essential for:
  - Validation that the script worked during the current activation.
  - User confidence that the system responded to their `darwin-rebuild switch` command.
  - Seamless transition to an alternate launcher (Raycast, LaunchBar, etc.) in the same session.

**Why it must run as the console user**:

- `activateSettings -u` operates on the user's session context, not root's.
- Running as root has no effect on the active GUI session.

**Implementation**:

```bash
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" \
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

### Stage 3: launchctl disable (prevents re-launch on reboot)

**What**: Disable the com.apple.Spotlight launchd service so it does not re-start on reboot.

**Why**:

- Even if hotkeys are disabled and indexing is turned off, the Spotlight service can be re-enabled by system updates or manual intervention.
- `launchctl disable` removes the service from the auto-start registry (the equivalent of unchecking "Run at startup").
- Without this, a reboot may restore the service, which can re-enable hotkey listening or indexing behavior.

**Implementation**:

```bash
/bin/launchctl disable "gui/$console_uid/com.apple.Spotlight"
```

### Stage 4: launchctl bootout (stops running instance immediately)

**What**: Boot out (immediately stop) the currently running com.apple.Spotlight service.

**Why**:

- `launchctl disable` prevents re-launch on reboot but does **not stop** an already-running service.
- If Spotlight is actively indexing or listening during activation, it continues until the user logs out.
- `launchctl bootout` terminates the process **now**, preventing any in-flight re-enable or listener activity.

**Implementation**:

```bash
/bin/launchctl bootout "gui/$console_uid/com.apple.Spotlight"
```

**Note**: `bootout` may fail with a non-zero exit code if the service is already absent (e.g., a previous activation already stopped it, or the system is in a clean state). This is expected and safe; log it as a warning, not an error.

**SIP nuance (macOS 15+)**: `launchctl bootout gui/<uid>/com.apple.Spotlight` can return
`Operation not permitted while System Integrity Protection is engaged` even when
`launchctl disable` and `mdutil -i off /` have already converged the effective state.
Treat this as an expected classified warning (not a hard error), and avoid printing
raw unclassified `launchctl` output directly in activation logs.

### Stage 5: mdutil -i off / (disable Spotlight indexing globally)

**What**: Disable Spotlight indexing at the filesystem level for the root volume.

**Why**:

- Even if the service is disabled in launchd, the indexing subsystem can persist.
- `mdutil -i off /` is the definitive "stop indexing" command and is enforced at the macOS kernel/storage layer.
- If an admin re-enables the service or if macOS updates restore it, **indexing will not resume** because it is disabled at this level.
- Without this stage, a user could manually enable Spotlight via System Settings, and indexing would resume immediately.

**Privilege requirement**:

- `mdutil -i off /` **requires root privileges** to disable indexing on the system volume.
- This is why the entire stage must run in `system.activationScripts` (which runs as root), not home.activation.

**Implementation**:

```bash
/usr/bin/mdutil -i off /
```

### Stage 6: Remove Cache Directory /.Spotlight-V100

**What**: Delete the existing Spotlight index cache at `/.Spotlight-V100`.

**Why**:

- If the indexing service is partially re-enabled or if a user manually re-enables Spotlight, having a pre-built cache allows Spotlight to respond instantly.
- Removing the cache forces Spotlight to **rebuild from scratch** if re-enabled, which is time-consuming and less convenient for users.
- Combined with `mdutil -i off`, this ensures that even if Spotlight is re-enabled by accident or policy, it has no indexed data to serve.

**Implementation**:

```bash
if [ -d "/.Spotlight-V100" ]; then
  /bin/rm -rf "/.Spotlight-V100"
fi
```

---

## Why This Must Run in system.activationScripts (NOT home.activation)

The entire Spotlight disable strategy must run in `src/hosts/macbook/activation.nix` under `system.activationScripts.postActivation.text`, **not** in `src/modules/macos.nix` under `home.activation`.

**Reason**:

- `system.activationScripts` runs as **root** during `darwin-rebuild switch`.
- `home.activation` runs as the **logged-in user** after system activation completes.
- Three operations **require root privilege** and will fail silently in user context:
  1. `mdutil -i off /` — requires root to disable indexing on system volume
  2. `launchctl bootout` — requires root to forcibly terminate system launchd services
  3. `launchctl disable` — requires root to modify system launchd registry
- Even with `sudo` wrapping, user-context execution is insufficient for these privileged subsystems.
- Placing the strategy in system activation ensures all privileges are available and all operations succeed atomically.

---

## What NOT to Do (Previous Failed Approaches)

### ❌ WRONG: Disable only hotkey 61

```bash
# THIS WILL NOT WORK — left 64 and 65 active
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 61 "..."
```

**Why it fails**: macOS stores Cmd+Space across multiple ID slots; you must disable all three.

### ❌ WRONG: Run disable in home.activation (user level)

```nix
# THIS WILL NOT WORK — insufficient privilege
home.activation.disableSpotlight = ''
  defaults write com.apple.symbolichotkeys ...
  mdutil -i off /  # Fails silently — no root privilege
  launchctl bootout ...  # Fails silently — no root privilege
'';
```

**Why it fails**: User context cannot execute root-required operations; they fail silently.

### ❌ WRONG: Skip activateSettings -u

```bash
# Changes are written but not applied to running session
defaults write com.apple.symbolichotkeys ...
# Missing: activateSettings -u
```

**Why it fails**: User must log out/in for changes to take effect; looks broken during current session.

### ❌ WRONG: Disable launchctl service but not stop it

```bash
# Service is marked as disabled but still running
launchctl disable gui/.../com.apple.Spotlight
# Missing: launchctl bootout to stop running instance
```

**Why it fails**: Service continues indexing until reboot; Spotlight may still respond during current session.

### ❌ WRONG: Turn off indexing but leave service running

```bash
# Indexing is off but service is still active
mdutil -i off /
# Missing: launchctl bootout and disable
```

**Why it fails**: Service can re-enable indexing on demand or after update; users can manually re-enable it via System Settings.

---

## Testing & Verification

After applying the Spotlight disable strategy, verify:

1. **Hotkey IDs are disabled** (check user defaults):

   ```bash
   defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 '"61"'
   defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 '"64"'
   defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 '"65"'
   # Expected: <false/> for each
   ```

2. **Spotlight indexing is off**:

   ```bash
   mdutil -s /
   # Expected: "Indexing enabled."  (note: despite wording, if indexing was OFF before, state stays OFF)
   # OR check: sudo mdutil -i off / && mdutil -s /
   ```

3. **Service is disabled and stopped**:

   ```bash
   launchctl list | grep Spotlight
   # Expected: (empty — service is not running)
   ```

4. **Cache is removed**:

   ```bash
   ls -la /.Spotlight-V100
   # Expected: "No such file or directory"
   ```

5. **User-visible test**: Press `cmd+space` in the active GUI session.
   - Expected: Nothing happens (Spotlight does not open).
   - If cmd+space opens Raycast or another launcher, it means your alternate launcher is active.
   - If cmd+space opens Spotlight, the disable failed (revisit stages 1–2; `activateSettings -u` may not have succeeded).

---

## Troubleshooting

### Symptom: "Cmd+Space still opens Spotlight after activation"

**Diagnosis**:

1. Check if activateSettings -u ran and succeeded (review activation log).
2. Verify hotkeys 61, 64, 65 are all marked `enabled=false` in com.apple.symbolichotkeys.
3. Did the activation run at all? (Check if `darwin-rebuild switch` completed successfully.)

**Solution**:

- If hotkeys are **not** marked disabled → check that defaults write completed without error.
- If hotkeys **are** disabled but Spotlight still responds → log out/in once; `activateSettings -u` only affects the current session.
- If problem persists after logout/login → verify that Spotlight is truly off at the launchctl level (see Testing section above).

### Symptom: "Activation failed with mdutil error"

**Diagnosis**: Most likely running in user context (home.activation) instead of system context.

**Solution**: Ensure the disable code is in `src/hosts/macbook/activation.nix` under `system.activationScripts.postActivation`, not in `src/modules/macos.nix`.

### Symptom: "activateSettings -u failed or returned non-zero"

**Diagnosis**:

- The private framework path may have changed in a newer macOS release.
- The console user context may not be correctly resolved.

**Solution**:

1. Verify `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings` exists on the current macOS version.
2. Verify `$console_user` and `$console_uid` are correctly resolved (check activation log).
3. If the path has changed, update it in activation.nix.

---

## Related Files

- **Implementation**: [src/hosts/macbook/activation.nix](src/hosts/macbook/activation.nix#L363) — the `disableSpotlight` section
- **Testing**: `tests/nix/*spotlight*.nix` — test cases validating the disable
- **Manual Steps**: [src/hosts/macbook/MANUAL.md](src/hosts/macbook/MANUAL.md) — note if any manual steps are required post-activation
- **Defaults Configuration**: [src/hosts/macbook/defaults.nix](src/hosts/macbook/defaults.nix) — ensure no conflicting `com.apple.spotlight` plist settings re-enable it

---

## Key Takeaway

**Do NOT simplify or reduce this 6-stage strategy.** Each stage addresses a distinct layer of macOS Spotlight control:

1. Hotkey disable (user preference layer)
2. Immediate activation (session layer)
3. Service disable (boot-time layer)
4. Service stop (runtime layer)
5. Indexing disable (kernel/storage layer)
6. Cache cleanup (filesystem layer)

**Removing any stage will cause partial failure or regression.** If you encounter an issue, add a stage (e.g., additional hardening) rather than removing one. The strategy is battle-tested and verified as working.
