---
description: "Use when debugging Android (LineageOS) VM display freezes on UTM for the MacBook host, or editing UTM renderer provisioning (macos-set-utm-renderer.sh, vms.nix, activation.nix, MANUAL.md). Covers the confirmed root cause, diagnostics, state-preserving recovery, and mitigations."
name: "UTM Android Freeze"
applyTo: "src/scripts/hosts/MacBook/macos-set-utm-renderer.sh, src/hosts/MacBook/vms.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md"
---

# UTM Android freeze — findings (2026-08-03)

The "display freezes randomly" bug is a **client-side SPICE display-channel stall** in UTM's SPICE client (CocoaSpice). It is renderer-orthogonal: not fixed by the renderer backend, not display sleep, not virgl, not guest-side.

## Root cause

- **CocoaSpice#5** (utmapp/CocoaSpice, osy 2024-12-19): race in `rebuildScanoutTextureWithScanout` → UTM deadlocks in `read()` on a pipe FD (the IOSurface ID is passed through a pipe; the same FD can be sent twice with stale size/format). Mitigated Dec 2024 (commits `8be7395`, `4aa7eea`) but "does not completely fix". osy (2026-07-06, UTM #2221): "If you get a spindump, see if UTM is stuck in a read call."
- **Renderer-orthogonal**: per `Documentation/Graphics.md`, ANGLE/CGL only renders INTO the IOSurface in QEMULauncher; CocoaSpice Metal ALWAYS presents to screen. Freeze occurs on both ANGLE(1) and CGL(3).
- **Backpressure chain**: client wedge → QEMU display channel stops consuming → virtio-gpu commands unacked → guest virtqueue fills → guest display pipeline stalls (`virtio_gpu_process_cmdq` = 0) while the guest stays alive. UTM #5886 kernel hung-task trace: `virtio_gpu_queue_ctrl_sgs` → `virtio_gpu_queue_fenced_ctrl_buffer` blocked; "VM responsive via SSH, not via UI".
- **Local refinement (2026-08-03)**: sampled SPICE Main Loop thread stuck in `playback_stop` → `gst_element_set_state` (GStreamer audio pipeline state change), 5013/5013 samples. spice-client-glib's single glib main loop dispatches ALL SPICE channels (display scanout, input, audio, clipboard, QMP-over-spiceport) → display frozen AND `utmctl suspend` fails with OSStatus -2700 "Timed out waiting for RPC" (QMP rides the same frozen spiceport channel). Trigger suspect: host default audio output = BlackHole 2ch virtual device (CamillaDSP install); the Android VM has no audio keys, so UTM applies its default SPICE audio backend (`-audiodev spice,id=audio0 -device intel-hda -device hda-duplex,audiodev=audio0`).

## References

- UTM #2221 "Display freezes randomly" — open, canonical; freezes after host idle and during active use (#5254); `NSAppSleepDisabled` "helps a bit, doesn't resolve"; visibility correlation (Metal renderer unhappy when the window is not visible) — zero-cost mitigation: keep the VM window visible.
- UTM #7212 — red herring: author closed it ("it's macOS itself"; used Apple Virtualization backend).
- UTM 5.0.4 (2026-08-01) — "SPICE: Fixed various bugs in renderer" + SPICE memory-leak fix; 5.0.1 CocoaSpice Metal renderer rework; 5.0.2 GL regression fix (#7626). Bug class still open: huuck reported freezes on 5.0.2 (2026-03-30).

## Diagnostics

1. During a freeze, sample the UTM app: `sample <utm-pid> 5 -mayDie`. Look for the SPICE Main Loop stuck in `playback_stop`/`gst_element_set_state`, or a CocoaSpice `read()` call (osy's diagnostic).
2. Sample qemu: `virtio_gpu_process_cmdq` = 0 while the guest is alive (userdata qcow2 mtime advancing, adb port open) → display pipeline backpressured, guest OK.
3. `utmctl suspend <vm>` → OSStatus -2700 "Timed out waiting for RPC" means the SPICE main loop is frozen (QMP-over-spiceport blocked), NOT a wedged UTM main thread.

## Recovery ladder (state-preserving, in order)

1. Switch the host audio output device (e.g., BlackHole 2ch → MacBook speakers); a CoreAudio device change may unblock the stuck GStreamer sink and resume the SPICE loop.
2. `adb connect localhost:5555` + `adb shell screencap` — proves the guest display renders fine and gives guest control (needs `brew install android-platform-tools`, user-level).
3. Controlled restart as last resort — guest disk (`userdata.qcow2`) is intact; guest RAM state is lost.

## Safety invariants

- **Never kill UTM.app to recover**: QEMUHelper.xpc is an Application-scoped XPC service (`ServiceType = Application`, no KeepAlive) — killing UTM.app cascades to QEMUHelper → VMs stop → guest RAM state LOST. `utmctl stop` is also state-lossy.
- The renderer pref (`QEMURendererBackend = 3`, CGL) is still provisioned (the Android UI requires a GL backend) but it does NOT fix the freeze.
