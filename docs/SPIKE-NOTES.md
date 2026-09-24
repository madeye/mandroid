# Phase 0 Spike Notes

All measurements were taken on 2026-09-10 with `Tools/Spike` (see the
commands below). Items marked **blocking** decided Phase 1–3 scope. Environment for the spike: reference SDK at
`/Volumes/DATA/workspace/android` (emulator 36.3.10), AVD `Medium_Phone`
(API 36.1, Google Play, arm64).

| # | Question | Blocking | Result |
|---|---|---|---|
| 1 | `getDisplayConfigurations`: values of `maxDisplays` and `userConfigurable` at runtime | yes | **Measured 2026-09-10**: `maxDisplays=11`, `userConfigurable=3` (emulator 36.3.10 and 37.1.11). Only ids 1–3 are creatable; the pool stays at 3 slots. |
| 2 | Display flags: does 1225 give a bar-free display that accepts `am start --display`? Does 9? Does `1225 \| 16384` (OWN_FOCUS) behave differently? | yes | **1225 works**: bar-free, `FLAG_TRUSTED | FLAG_OWN_CONTENT_ONLY | FLAG_ROTATES_WITH_CONTENT`, `am start --display` launches there. **9 fails**: display is created untrusted (no `FLAG_TRUSTED`), `am start --display` silently launches nothing and the emulator reports "guest has not posted new frame yet". **17609 (1225 \| OWN_FOCUS)** creates a display with `FLAG_OWN_FOCUS`, renders identically; no benefit observed, not used. |
| 3 | Mapping from emulator display index (1–3) to Android logical display id: `dumpsys display` fields available, is size a reliable join key? | yes | **Deterministic join key**: emulator display *N* appears as `uniqueId="virtual:com.android.emulator.multidisplay:123456<N+1>"` (1→…2, 2→…3, 3→…4), name `"Emulator 2D Display"`, `deviceProductInfo null`; display 0 is `local:…` with `deviceProductInfo name=EMU_display_0`. The logical `displayId` is *not* stable (2 on first creation, 5 after a reboot and re-creation) so it must always be re-read. Size remains a fallback key. Fixtures: `MandroidKitTests/Fixtures/dumpsys-display-*.txt`. |
| 4 | In-place resize: after `setDisplayConfigurations` with a new size for an existing id, does the Settings activity survive (config change) or restart / move to display 0? | yes | **Survives**: changing display 1 from 840×1800 to 1400×900 kept `displayId` and `uniqueId`, the same `ActivityRecord` hashes stayed resumed (no restart, no move to display 0) and Settings relaid out in landscape. `setDisplayConfigurations` returned in 2 ms; Android applied it within ~1 s. |
| 5 | Focus nudge: does a `MouseEvent{buttons:0}` (or tap) to display 1 change `mTopFocusedDisplayId`, and do subsequent `sendKey` events land on display 1? | yes | **Keys follow `FocusedDisplayId`** (`dumpsys input`, also `mTopFocusedDisplayId` in `dumpsys window`), which follows the last *touched* display. A `MouseEvent{buttons:0}` hover does **not** move it (no mouse device in the guest). `am start --display <id> -n <component>` of the window's own activity **does** move it ("intent delivered to top-most instance", no relaunch). After the move, `sendKey` text and named keys landed in the field on display 1; `show_ime_with_hard_keyboard 0` kept the IME hidden. Policy: nudge with `am start --display` on `windowDidBecomeKey` unless our last touch already went to that display. |
| 6 | MMAP transport: does `ImageTransport{channel: MMAP, handle: "file:///…"}` produce frames? Region byte layout, stride, header, tearing observed? | yes | **Crashes the emulator**: `ImageTransport{channel: MMAP, handle: "file:///…"}` (and a bare path) aborts qemu with `mutex lock failed: Invalid argument` on 36.3.10. MMAP is dropped from the plan; the gRPC path is fast enough (see 10). |
| 7 | Frame row order: top-down or bottom-up as the proto comment claims? | no | **Top-down.** RGBA8888 bytes render correctly as `CGImage` with `byteOrder32Big | noneSkipLast`, no flip needed. |
| 8 | `injectWheel` on the phone image: scrolls, or silently dropped? | no | **Dropped** on the stock image (no wheel-capable input device). With `-feature VirtioMouse` a `QEMU Virtio Mouse` appears and `injectWheel` scrolls display 0 only, but that feature **removes the per-display `virtio_input_multi_touch_N` devices** so touch stops working everywhere and the snapshot is invalidated. Never enable it; two-finger scroll is synthesised as a touch drag. Scrolling instead injects mouse `ACTION_SCROLL` from the `ScrollInjector` app_process helper, which works on every display (API 36: one axis unit = 64 dp in standard containers). |
| 9 | Boot times: cold boot vs quickboot snapshot restore (wall clock to `sys.boot_completed`) | no | First boot (fresh AVD, data wipe): 31 s. Cold boot of an initialised AVD: 18 s. Quickboot snapshot restore: 6.2 s (to `sys.boot_completed`, M-series Mac, 4 cores / 4 GB). |
| 10 | Sustained fps and host CPU over gRPC at 720×1280, 1080×1920, 1080×2400 (RGBA8888, scrolling content) | no | Release build, continuous scrolling content, single `streamScreenshot`: 420×900 48.8 fps (74 MB/s); 840×1800 49.3 fps (299 MB/s); 1080×2400 (display 0) 50 fps (520 MB/s). Client ~15–20 % of one core, qemu ~50–60 %. Debug builds are 3–5× slower (SwiftProtobuf decode) — profile only Release. Requests larger than the display are capped to the display size. Response cap: the NIO transport sizes its inbound decoder from **`maxRequestMessageBytes`**, so both `maxRequestMessageBytes` and `maxResponseMessageBytes` must be raised (64 MiB). |
| 11 | Bootstrap without Java: emulator boots from a hand-written AVD (no `hw.device.name`/`hash2`) in an isolated SDK root with no `platforms/` directory? Any warnings? | yes | **Works.** Emulator 37.1.11 + platform-tools 37.0.1 from `dl.google.com`, extracted with `ditto -x -k` into an empty root with only `licenses/`, hand-written `runner.ini` + `runner.avd/config.ini` (no `hw.device.name`/`hash2`, `skin.path=_no_skin`), system image symlinked in. No `platforms/` directory, `PATH` without any JDK, isolated `ANDROID_*_HOME` and `ANDROID_ADB_SERVER_PORT=5137`: boots, gRPC and multi-display work. Only warnings: metrics notice (pass `-no-metrics`) and missing `emu-update-last-check.ini`. The emulator **writes `hw.displayN.*` back into the AVD `config.ini`** and re-creates those displays on the next boot, so startup must reset the display set (`setDisplayConfigurations` with an empty list works). |
| 12 | Quarantine: does a `URLSession`-downloaded emulator zip carry `com.apple.quarantine` after `ditto` extraction? Does the emulator launch and use HVF? | yes | No `com.apple.quarantine` on the downloaded zip (curl) nor on the extracted binaries; `qemu-system-aarch64` keeps Google's signature (Team `EQHXZ8M8AV`, `com.apple.security.hypervisor` entitlement) and boots with HVF. `URLSession` may behave differently for an app with `LSFileQuarantineEnabled`; the bootstrap strips the attribute defensively anyway. |
| 13 | Permission dialogs: does a runtime permission prompt from an app on display 1 appear on display 1 or display 0? | no | **On the app's display.** Camera's location permission prompt (`GrantPermissionsActivity`) opened on display 5 (= emulator display 1) where the app runs; display 0 stayed on the launcher. |
| 14 | IME: with `show_ime_with_hard_keyboard 0` and injected keys, does the soft keyboard stay hidden on the secondary display? | no | Hidden: `mInputShown=false` after typing into a focused field on display 1 with `show_ime_with_hard_keyboard 0`. |
| 15 | Wheel/scroll and multitouch: pinch-zoom via two `Touch` identifiers works? | no | Not measured (non-blocking). Multi-touch identifiers are supported by the proto; test when a pinch gesture is implemented. Wheel/scroll: see row 8. |

## Commands and snippets

```bash
# Boot headless with gRPC
$ANDROID_HOME/emulator/emulator -avd Medium_Phone -grpc 8554 -qt-hide-window \
  -no-boot-anim -gpu host -feature Vulkan
adb wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'

# Display state on the Android side
adb shell dumpsys display | grep -E 'mDisplayId|uniqueId|DisplayDeviceInfo|mBaseDisplayInfo'
adb shell dumpsys window | grep -E 'mTopFocusedDisplayId|mFocusedWindow'
adb shell dumpsys activity activities | grep -E 'displayId|Task|Hist'

# Launch on a display
adb shell am start --display <id> -n com.android.settings/.Settings
adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <pkg>

# Display-targeted key event (slow path)
adb shell input -d <id> keyevent KEYCODE_BACK
```

Record raw `dumpsys display` output before and after creating a display as a
fixture under `MandroidKitTests/Fixtures/` once captured.
