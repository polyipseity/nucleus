---
description: "Use when debugging Android (LineageOS) VM display freezes on UTM for the MacBook host, or editing UTM renderer provisioning (macos-set-utm-renderer.sh, vms.nix, activation.nix, MANUAL.md). Covers the confirmed root cause, the audio-disable workaround, diagnostics, state-preserving recovery, and mitigations."
name: "UTM Android Freeze"
applyTo: "src/hosts/MacBook/scripts/macos-set-utm-renderer.sh, src/hosts/MacBook/vms.nix, src/hosts/MacBook/activation.nix, src/hosts/MacBook/MANUAL.md"
---

# UTM Android freeze — findings (2026-08-03)

The "display freezes randomly" bug is a **client-side deadlock in UTM's SPICE client** (CocoaSpice): the SPICE main loop's GStreamer audio-pipeline teardown deadlocks against the CoreAudio IO thread, stalling all SPICE channels (display scanout, input, audio, QMP-over-spiceport). It is renderer-orthogonal: not fixed by the renderer backend, not display sleep, not virgl, not guest-side.

## Root cause

- **Confirmed (2026-08-03, full-process sample 4253 ms): two-thread AB-BA circular deadlock inside UTM.app.** Both threads parked in `__psynch_mutexwait` for the whole sample (4253/4253 each; total mutex-wait hits = 8506 = exactly 2 threads × 4253 → provably no other mutex-stuck thread in the process):
  - Thread A — SPICE Main Loop: `playback_stop (spice-client-glib) → gst_element_set_state (×3) → gst_audio_ring_buffer_stop → AudioOutputUnitStop → HALC_ProxyIOContext::StopIOProc → HALB_Mutex::Lock`. Holds the audio unit's internal recursive mutex (taken inside `AudioOutputUnitStop`), wants the IO-context lock.
  - Thread B — `com.apple.audio.IOThread.client`: `HALC_ProxyIOContext::IOWorkLoop → [UTM render callback 0x1004e65a8] → AudioUnitSetProperty → std::recursive_mutex::lock`. Holds the IO-context lock, wants the audio unit mutex. The classic "call an AU API from the render thread" race.
  - **Trigger (revised)**: guest audio goes idle → SPICE sends `playback_stop` → GStreamer sink teardown races the render callback's AU call. Device-independent — the stacks contain no HALC device-change frame, so switching the host output device is irrelevant (BlackHole 2ch / CamillaDSP context is a red herring); this is why the freeze recurs. The pipeline stays PLAYING (GStreamer stops sink → source): `appsrc:src` and `queue0:src` idle in `g_cond_wait`, upstream never stopped. The VM's `Sound = intel-hda` maps to `-audiodev spice,id=audio0 -device intel-hda -device hda-duplex,audiodev=audio0`.
  - Renderer stays alive during the freeze: `CVDisplayLink` in `cvwait` with 14 active `performIO`; MTKView draws on the main thread — the frozen image is a stale texture, not a renderer stall.
  - Guest has a parallel userspace stall, separate from the client deadlock: adbd wedged (`adb devices` → `offline`; AUTH/CNXN probes to 5555/5554 return 0 bytes) while `data/Android.qcow2` mtime keeps advancing.
- **CocoaSpice#5** (utmapp/CocoaSpice, osy 2024-12-19): race in `rebuildScanoutTextureWithScanout` → UTM deadlocks in `read()` on a pipe FD (the IOSurface ID is passed through a pipe; the same FD can be sent twice with stale size/format). Mitigated Dec 2024 (commits `8be7395`, `4aa7eea`) but "does not completely fix". osy (2026-07-06, UTM #2221): "If you get a spindump, see if UTM is stuck in a read call." Not evidenced in the confirmed sample (no `read()` frame) — the audio deadlock is the mechanism.
- **Renderer-orthogonal**: per `Documentation/Graphics.md`, ANGLE/CGL only renders INTO the IOSurface in QEMULauncher; CocoaSpice Metal ALWAYS presents to screen. Freeze occurs on both ANGLE(1) and CGL(3).
- **Backpressure chain (candidate, not active in the confirmed sample)**: client wedge → QEMU display channel stops consuming → virtio-gpu commands unacked → guest virtqueue fills → guest display pipeline stalls (`virtio_gpu_process_cmdq` = 0) while the guest stays alive. UTM #5886 kernel hung-task trace: `virtio_gpu_queue_ctrl_sgs` → `virtio_gpu_queue_fenced_ctrl_buffer` blocked; "VM responsive via SSH, not via UI". In the confirmed sample qemu's SPICE Worker sat idle in `g_poll` (3902/3902) — not backpressured.

## Confirmed workaround (2026-08-04, TESTED)

Disabling guest audio is the ONLY known prevention: with an empty `Sound` array, qemu runs `-audio none -audiodev spice,id=audio0` with no `intel-hda`/`hda-duplex` device, so the SPICE audio pipeline never exists and the teardown/IO-thread race cannot occur. Live-tested 2026-08-04: guest boots and runs with 0 deadlock signatures in a 5 s sample; tradeoff is no guest audio.

The workaround is now repo-managed: the `VMs.json` Android entry declares `"sound": "none"`, `src/hosts/MacBook/vms.nix` renders the `__VM_SOUND__` token in `src/modules/configs/vms/utm-config.plist.xml` to an empty Sound array (any other value or absent → `intel-hda`, preserving all non-Android VMs). The `<key>Sound</key>` key stays literal in the template (`_required_utm_keys` in `src/scripts/lib/vm.sh`). Re-provision-safe: `nucleus-vm setup Android` refreshes the bundle's `config.plist` from the template, which now emits `<array/>`.

The guest-side adb wedge (`adb devices` → `offline`) is a SEPARATE guest-side issue — it persists with the workaround and is not caused by it.

Revert procedure: restore the audio-enabled plist from `/tmp/Android.utm.config.plist.bak` (live bundle) or flip the Android `sound` field back in `VMs.json` (repo). Do this ONLY after an upstream fix lands (see References).

## References

- UTM #2221 "Display freezes randomly" — open, canonical; freezes after host idle and during active use (#5254); `NSAppSleepDisabled` "helps a bit, doesn't resolve"; visibility correlation (Metal renderer unhappy when the window is not visible) — zero-cost mitigation: keep the VM window visible.
- UTM #2364 — `AURemoteIO::Stop: error 268451843 calling TerminateOwnIOThread (port 94231)`; closed by osy 2022-12-27, milestone v4.1 — audio IO-thread teardown race, same class as the confirmed deadlock.
- UTM #4781 — open; M1 Max, UTM 4.0.9; "Freeze up... unless playing audio" — audio-state correlation.
- UTM #7212 — red herring: author closed it ("it's macOS itself"; used Apple Virtualization backend).
- UTM 5.0.4 (2026-08-01) — "SPICE: Fixed various bugs in renderer" + SPICE memory-leak fix; 5.0.1 CocoaSpice Metal renderer rework; 5.0.2 GL regression fix (#7626). Bug class still open: huuck reported freezes on 5.0.2 (2026-03-30).
- Upstream status: NO fix exists as of UTM 5.0.4 (2026-08-01). Open: #2221 (canonical), #4781, #7468 "Apply CoreAudio patches from akihikodaki/qemu" (milestone Future). UTM's `patches/gst-plugins-good-1.19.1.patch` (osxaudio teardown reorder — remove render callback before `AudioOutputUnitStop`) predates 5.0.4 and is incomplete mitigation. Revert the workaround only after an upstream fix lands; test in a non-Android VM first or keep a `.bak`.
- GStreamer discourse 5489 (2025-11) — `gst_element_set_state()` hangs setting an element to NULL (embedded/Linux context) — same hang class as the confirmed deadlock, not an Apple mechanism.

## Diagnostics

1. During a freeze, sample the UTM app: `sample <utm-pid> 5 -mayDie`. Look for the SPICE Main Loop stuck in `playback_stop`/`gst_element_set_state`, or a CocoaSpice `read()` call (osy's diagnostic).
2. Sample qemu: `virtio_gpu_process_cmdq` = 0 while the guest is alive (userdata qcow2 mtime advancing, adb port open) → display pipeline backpressured, guest OK.
3. `utmctl suspend <vm>` → OSStatus -2700 "Timed out waiting for RPC" means the SPICE main loop is frozen (QMP-over-spiceport blocked), NOT a wedged UTM main thread.
4. Full-thread census: the sample's `__psynch_mutexwait` total equals N × sample-count iff exactly N threads are mutex-stuck (e.g. 8506 = 2 × 4253 → exactly the SPICE Main Loop and the IO thread). Every other thread must sit in a normal wait (`g_cond_wait`, `__select`, `mach_msg`, `semaphore_wait_trap`).
5. adb during a freeze: `adb devices` shows `offline`; `nc -z` only proves the TCP listener accepts, not that adbd answers — probe protocol bytes (AUTH/CNXN) to confirm adbd is wedged (0 bytes returned).
6. Process name: the Android VM's qemu process is `qemu-aarch64-softmmu` (QEMULauncher child), not `qemu-system-aarch64` — filter `pgrep -fl` accordingly.
7. plutil is lossy on UTM configs: `plutil -remove` rewrites the whole plist (8-space indent, drops comments, reorders keys) → UTM rejects the import. Always use surgical text edits (e.g. python3 regex) on `config.plist`.

## Recovery ladder (state-preserving, in order)

1. **Prevent — keep guest audio disabled (the workaround above).** This is the only prevention; it is repo-managed and re-provision-safe.
2. **Controlled restart — the ONLY working recovery.** Both deadlocked threads park in process-local pthread mutex waits (`__psynch_mutexwait`); no external event (device switch, coreaudiod restart) can release them — the deadlock persists until UTM.app exits. Quit UTM (`kill -TERM $(pgrep -x UTM)`; osascript may cancel with -128), relaunch, then `nucleus-vm start Android`. Guest disk (`userdata.qcow2`) is intact; guest RAM state is lost.
3. **Switch the host audio output device — INVALID (2026-08-03).** A CoreAudio device change cannot release in-process pthread mutexes; coreaudiod has no wakeup path into the parked threads. The confirmed stacks contain no HALC device-change frame, and the deadlock is device-independent — this step never worked.
4. **`adb connect` + `screencap` — FAILS in this freeze class (2026-08-03).** The guest's adbd is itself wedged (persistent `offline`, 0-byte AUTH/CNXN probes) — a parallel guest-side stall, separate from the host deadlock. May still prove the guest display renders when adbd is healthy, but cannot recover the host deadlock.

## Safety invariants

- **Killing UTM.app is state-lossy — do it deliberately, not as a naive unstick**: QEMUHelper.xpc is an Application-scoped XPC service (`ServiceType = Application`, no KeepAlive) — killing UTM.app cascades to QEMUHelper → VMs stop → guest RAM state LOST. It is nevertheless the ONLY recovery for the audio deadlock (ladder step 2). `utmctl stop` is also state-lossy.
- The renderer pref (`QEMURendererBackend = 3`, CGL) is still provisioned (the Android UI requires a GL backend) but it does NOT fix the freeze.
