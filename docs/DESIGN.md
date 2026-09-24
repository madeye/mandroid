# Mandroid for macOS — Design

Status: working prototype (updated 2026-09-17). This document records the
architecture, measured constraints, and implementation decisions. See
[PLAN.md](PLAN.md) for completed and outstanding work,
[SPIKE-NOTES.md](SPIKE-NOTES.md) for the original measurements, and
[KERNELSU.md](KERNELSU.md) for optional rooted-boot setup and recovery.

## 1. Goals and non-goals

### Goals

- Run Android apps on a Mac so that **each app looks and behaves like a native
  macOS app**: its own `NSWindow` with a standard title bar, resizable, Cmd
  shortcuts, clipboard sync, Dock/Spotlight presence, and **no emulator skin
  and no Android status or navigation bars**.
- Build on the **stock Android Emulator** (QEMU-based, from Google's SDK
  repository). We do not fork or patch the emulator; we drive it through its
  public gRPC API and adb.
- **Self-contained**: the app downloads the emulator, platform-tools, a system
  image and `aapt2` on first launch. No Java, no Android Studio, no `sdkmanager`
  or `avdmanager` on the user's machine.
- **Pure Swift** (AppKit + SwiftUI), macOS 15+, **Apple silicon only**
  (`ARCHS = arm64`; arm64 system images under HVF). The manifest parser still
  understands `host-arch = x64` entries but nothing selects them.

### Non-goals (for now)

- Running apps that require Play Integrity / SafetyNet attestation. They
  detect the emulator and refuse to run; this is a stated product limitation.
- Physical Android devices as a backend (see "Future" for how it could fit).
- More than three concurrent app windows per emulator instance (a hard
  emulator limit, see §3.2).
- Android system UI features that make no sense on a desktop (lock screen,
  quick settings, notification shade as such).

## 2. Prior art and why this shape

- **Windows Subsystem for Android** (Microsoft, retired 2025) is the user
  experience we target: an app list, one window per Android app, native window
  chrome, clipboard integration.
- **Android Studio's embedded emulator** ("Running Devices") proves the
  transport: the emulator started with `-qt-hide-window` and driven purely over
  gRPC (`streamScreenshot`, `sendTouch`, `sendKey`, multi-display support).
- **scrcpy 3 `--new-display`** shows that "an app on a private virtual display,
  streamed into a desktop window" works well on Android 10+; it is our fallback
  provider if we ever need more than three displays or hardware video encoding.

## 3. Verified facts the design rests on

Everything in this section was checked against the SDK on disk, the emulator
source (`platform/external/qemu`, branch `emu-master-dev`), the emulator binary
string table, AOSP documentation, or Google's live repository manifests during
the design phase. Items still to be measured are listed in SPIKE-NOTES.md.

### 3.1 Emulator gRPC surface (`android.emulation.control.EmulatorController`)

Shipped proto: `<sdk>/emulator/lib/emulator_controller.proto` (vendored to
`Protos/` in this repo). The RPCs we rely on:

| RPC | Use | Display-aware |
|---|---|---|
| `streamScreenshot(ImageFormat) → stream Image` | Frames per display, RGBA8888, **server-side scaled** to requested `width`/`height` (capped at the display size). `ImageTransport.MMAP` crashes the emulator and is not used | yes (`display`) |
| `streamInputEvent(stream InputEvent)` | One bidirectional stream carrying touch, mouse, wheel, key and Android events in a `oneof` | per event |
| `sendTouch` / `sendMouse` / `injectWheel` / `sendKey` | Unary fallbacks | touch/mouse/wheel yes, **keyboard no** |
| `setDisplayConfigurations` / `getDisplayConfigurations` | Add, resize and remove secondary displays (ids 1–3); id 0 is immutable; displays omitted from the request are removed | — |
| `setClipboard` / `streamClipboard` | Two-way clipboard sync | — |
| `streamNotification` | `TextViewFocus{textViewHasFocus, display}`, boot/brightness events. Does **not** fire for display changes made over gRPC | — |
| `getStatus`, `setVmState`, `streamLogcat`, `streamAudio` | Health, shutdown, diagnostics, audio (VM-wide, not per display) | — |

Command-line flags: `-grpc <port>` (an explicit port disables JWT auth on
loopback), `-qt-hide-window` (Qt initialised but hidden; the mode Android
Studio uses), `-no-boot-anim`, `-gpu host`, `-feature Vulkan`,
`-idle-grpc-timeout`.

`KeyboardEvent` has `codeType` (Usb/Evdev/XKB/Win/Mac), `eventType`, `keyCode`,
`key` (W3C DOM key names such as `Enter`, `Backspace`, `GoBack`, `GoHome`) and
`text` (UTF-8 typed text). It carries **no display id**.

### 3.2 Multi-display facts (from emulator source)

Sources: `android/android-emu/android/emulation/MultiDisplay.cpp`,
`android/android-grpc/services/emulator-controller/server/src/android/emulation/control/EmulatorService.cpp`,
`android/android-emu/android/emulation/AutoDisplays.h`,
`android/emu/avd/src/android/avd/info.c`;
`host-common/MultiDisplay.h` in `platform/hardware/google/aemu`.

- **Hard cap of 3 user-configurable secondary displays.**
  `avdInfo_maxMultiDisplayEntries()` returns 3 and the gRPC handler rejects ids
  outside `[1, 3]`. Internal ids 6–10 exist for Android Auto and are not
  reachable through `setDisplayConfigurations`. The binary's string table
  agrees: `Multidisplay index should be 1, 2, or 3`.
- **Flags must be explicit.** With `flags == 0` on API ≥ 31 the emulator
  substitutes
  `PUBLIC | OWN_CONTENT_ONLY | ROTATES_WITH_CONTENT | TRUSTED | SUPPORTS_TOUCH | SHOULD_SHOW_SYSTEM_DECORATIONS | PRESENTATION`,
  i.e. the display gets Android's status and navigation bars. Flag bits
  (`DisplayManager` hidden constants, mirrored in `AutoDisplays.h`):

  | Flag | Bit |
  |---|---|
  | `VIRTUAL_DISPLAY_FLAG_PUBLIC` | 1 |
  | `VIRTUAL_DISPLAY_FLAG_PRESENTATION` | 2 |
  | `VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY` | 8 |
  | `VIRTUAL_DISPLAY_FLAG_SUPPORTS_TOUCH` | 64 |
  | `VIRTUAL_DISPLAY_FLAG_ROTATES_WITH_CONTENT` | 128 |
  | `VIRTUAL_DISPLAY_FLAG_DESTROY_CONTENT_ON_REMOVAL` | 256 |
  | `VIRTUAL_DISPLAY_FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS` | 512 |
  | `VIRTUAL_DISPLAY_FLAG_TRUSTED` | 1024 |
  | `VIRTUAL_DISPLAY_FLAG_OWN_FOCUS` (API 34+) | 16384 |

  We use **1225** = `PUBLIC | OWN_CONTENT_ONLY | SUPPORTS_TOUCH |
  ROTATES_WITH_CONTENT | TRUSTED`: a trusted, touch-capable, non-mirroring
  display with no system bars. The spike also tries the minimal `9`
  (`PUBLIC | OWN_CONTENT_ONLY`) and `1225 | OWN_FOCUS`.
- **Resizing is in place.** `setDisplayConfigurations` snapshots the current
  displays, skips entries whose configuration is unchanged, deletes displays
  missing from the request, and for changed entries calls
  `setMultiDisplay(id, …, add=true)`. `createDisplay` returns early when the id
  already exists, `setDisplayPose` updates width/height/dpi, and the guest
  multi-display pipe receives the new geometry. Android therefore sees a
  configuration change, not a hot-unplug.
- Validation: dpi 120–640; width and height ≥ 320 dp (`320 * dpi / 160` px);
  at most 8K; no duplicate ids. Multi-display requires the device rotation to
  be 0 and is unavailable on resizable, foldable, TV, Wear and guest-mode AVDs.
  The AVD must be a plain phone profile.
- The guest-side multi-display service
  (`com.android.emulator.multidisplay/.MultiDisplayServiceReceiver`) is
  started over adb; the emulator logs "Adb unavailable, not starting
  multidisplay service" otherwise. **adb must be connected before displays are
  added.**

### 3.3 Android behaviour on secondary displays

Device screen profiles (`DeviceProfile`, persisted by `RunnerSettings`) set
the built-in AVD's resolution and density. Tablet retains the default
2560×1600 at 320 dpi; phone and compact-phone profiles provide smaller logical
layouts. Custom dimensions are bounded in dp before conversion to pixels.
`AVDStore.write` detects effective geometry changes and the coordinator
skips the old quickboot snapshot, preserving userdata. Profiles do not alter
the system image, device identity, or the geometry of separate app windows.

- An activity launched from an activity on display N is placed on display N by
  default (AOSP activity-launch policy). Shell-initiated launches use
  `am start --display <id>`.
- Stock images ship `config_perDisplayFocusEnabled = false`: there is one
  keyboard-focused window device-wide, on the "top focused display". Touching a
  display makes it the top focused display.
- Permission dialogs are launched on behalf of the requesting activity and
  should follow its display; to be confirmed in the spike.
- `settings put secure show_ime_with_hard_keyboard 0` keeps the soft keyboard
  hidden while we inject hardware key events.

### 3.4 Self-contained SDK bootstrap

Google's SDK repository is plain XML fetched without authentication; this is
exactly what `sdkmanager` does.

| Component | Manifest | Package / archive (September 2026) | Size |
|---|---|---|---|
| Emulator | `https://dl.google.com/android/repository/repository2-3.xml` | `emulator`, channel-0 (stable) 37.1.11, `emulator-darwin_aarch64-<build>.zip` (the x64 variant is ignored) | ≈ 394 MB |
| platform-tools | same | `platform-tools`, `platform-tools_r37.0.1-darwin.zip` | ≈ 16 MB |
| System image | `https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml` | `system-images;android-36.1;google_apis_playstore;arm64-v8a` → `arm64-v8a-36.1_r04.zip` (android-36 and android-35 also listed; `google_apis` variants under `sys-img/google_apis/`) | ≈ 1.96 GB |
| aapt2 | `https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/maven-metadata.xml` | `aapt2-<ver>-osx.jar` (a zip containing a universal `aapt2` binary) | ≈ 4.5 MB |

Each `<remotePackage>` carries `<channelRef>`, `<revision>` and one or more
`<archive>` entries with `host-os` (`macosx`), `host-arch` (`aarch64` / `x64`),
a relative `url`, `size` and a SHA-1 `checksum`. Archive URLs are resolved
against the manifest's directory. Build ids change every release, so the
manifest is parsed at runtime and nothing is hard-coded except the package
paths.

**Download mirrors** (`DownloadMirror`). Google's hosts are unreachable from
mainland China and `dl.google.cn` no longer resolves, so the bootstrap can
fetch from a mirror: Tencent Cloud (`mirrors.cloud.tencent.com/AndroidSDK/`,
a byte-identical mirror of `dl.google.com/android/repository/` with range
support) for the SDK and system images, and Aliyun's Google Maven proxy
(`maven.aliyun.com/repository/google/`) for aapt2. Manifests are fetched from
the mirror, so the relative archive URLs resolve to it; SHA-1 checks still
apply. Selection is a user setting (`downloadMirror`: automatic, Google,
China). Automatic picks the China mirror only when the Mac's region is `CN`
or its time zone is a mainland-China zone; everyone else downloads from
Google only and never contacts the mirror hosts. When the mirror is used,
Google stays behind it as a fallback per manifest and per archive (a mirror
can lag a release); the reverse fallback does not exist.

Manifest parsing traps (all confirmed against the live manifests; each becomes
a unit test with the manifests committed as fixtures):

- **Channel filtering is mandatory.** `repository2-3.xml` lists two
  `<remotePackage path="emulator">` entries (channel-0 stable 37.1.11 under
  `android-sdk-license`, channel-2 dev 37.2.x under
  `android-sdk-preview-license`). A first-match parser picks the wrong one.
- **Archive URLs resolve against the manifest's own directory.** The Play
  image archive is `arm64-v8a-36.1_r04.zip`, relative to
  `…/repository/sys-img/google_apis_playstore/`, not the repository root.
- **A missing `<host-arch>` means universal.** platform-tools ships one
  `macosx` archive with no `host-arch` element; a strict arch filter finds
  nothing.
- **Licenses are per manifest and differ by package.** The arm64 Play image
  uses `android-sdk-arm-dbt-license`, which is only defined in the
  system-image manifest. Onboarding resolves license text from the manifest
  each package came from and shows it before download.
- **Dependencies are declared.** The android-36.1 image requires
  `emulator` ≥ 35.4.9 (`<dependency>` / `<min-revision>`); the bootstrap plan
  checks them.

License files: `<sdk>/licenses/<license-id>` containing the SHA-1 of the
accepted license text (currently `android-sdk-license` =
`24333f8a63b6825ea9c5514f83c2829b004d1fee`, `android-sdk-arm-dbt-license` =
`859f317696f67ef3d7f30a50a5560e7834b43903`; recompute from the manifest text
at runtime rather than hard-coding). Only `sdkmanager` reads them; we write
them so the tree is a valid SDK.

No JVM is involved anywhere: `otool -L` on `emulator`, `adb` and `aapt2` shows
only system frameworks and their own dylibs. `aapt2` from the Maven `-osx.jar`
is a universal Mach-O binary (≈ 11 MB unpacked): unzip, `chmod +x`, run.

No `platforms/` directory is required. The emulator validates the SDK root by
looking for a kernel under `system-images/` (its own error string:
"ANDROID_SDK_ROOT is defined … but cannot find kernel file in
…/system-images/ sub directories").

AVD without `avdmanager`: two files.

```
<ANDROID_AVD_HOME>/runner.ini
    avd.ini.encoding=UTF-8
    path=<abs path>/runner.avd
    path.rel=avd/runner.avd
    target=android-36.1

<ANDROID_AVD_HOME>/runner.avd/config.ini
    AvdId=runner
    avd.ini.displayname=Mandroid
    avd.ini.encoding=UTF-8
    abi.type=arm64-v8a
    hw.cpu.arch=arm64
    tag.id=google_apis_playstore
    tag.display=Google Play
    image.sysdir.1=system-images/android-36.1/google_apis_playstore/arm64-v8a/
    PlayStore.enabled=true
    target=android-36.1
    hw.device.manufacturer=Google
    hw.lcd.width=2560
    hw.lcd.height=1600
    hw.lcd.density=320
    hw.initialOrientation=portrait # natural orientation; panel is landscape
    skin.name=2560x1600
    skin.path=_no_skin
    skin.dynamic=yes
    showDeviceFrame=no
    hw.keyboard=yes
    hw.mainKeys=no
    hw.gpu.enabled=yes
    hw.gpu.mode=host
    hw.ramSize=4096
    hw.cpu.ncore=4
    vm.heapSize=512
    disk.dataPartition.size=16384M
    sdcard.size=512M
    hw.audioInput=yes
    hw.camera.back=virtualscene
    hw.camera.front=emulated       # webcam0 when Settings enables the Mac's camera
    hw.gps=yes
    hw.battery=yes
    hw.accelerometer=yes
    hw.gyroscope=yes
    hw.sensors.orientation=yes
    hw.sensors.proximity=yes
    fastboot.forceFastBoot=yes
    fastboot.forceColdBoot=no
    runtime.network.latency=none
    runtime.network.speed=full
```

The default uses Pixel Tablet resolution (2560×1600), a 320 dpi logical
density (1280×800 dp), and the same ARM64 Google Play system image. Existing
AVDs retain installed apps and data; changing display geometry, the GPU
backend or a camera mode skips loading the old quickboot snapshot on the next
boot (the guest camera HAL enumerates host cameras once at boot). The
emulator ships no `devices.xml`; `hw.device.name` is a plain string with no
catalogue lookup, so every `hw.*` value must be written explicitly and
`hw.device.hash2` (an Android Studio artefact) is omitted.

Host camera and microphone (Settings ▸ Camera & Microphone, both off by
default so a fresh install never shows a macOS privacy prompt): the camera
toggle sets `hw.camera.front=webcam0`, the first camera macOS reports via
`emulator -webcam-list`; the back camera keeps the virtual scene. The
microphone toggle adds `-allow-host-audio` to the command line; `hw.audioInput`
is always `yes`, but without that flag the emulator zero-fills captured audio
and apps record silence. QEMU is Mandroid's child process, so macOS attributes
its camera and microphone use to Mandroid: the app bundle carries
`NSCameraUsageDescription`/`NSMicrophoneUsageDescription` and the hardened
runtime entitlements `com.apple.security.device.camera` and
`com.apple.security.device.audio-input` (the signed QEMU binary has the same
entitlements). Change the toggles and restart Android to apply them.

Environment isolation for every `emulator` and `adb` process we spawn, so the
user's own `~/.android` and Android Studio are never touched:

```
ANDROID_SDK_ROOT / ANDROID_HOME = ~/Library/Application Support/Mandroid/sdk
ANDROID_AVD_HOME               = ~/Library/Application Support/Mandroid/avd
ANDROID_EMULATOR_HOME          = ~/Library/Application Support/Mandroid/emu-home
ANDROID_ADB_SERVER_PORT        = a dedicated port (default adb server on 5037 is left alone)
```

Google's emulator zip is code-signed with the hypervisor entitlement. We
extract with `/usr/bin/ditto -x -k` (preserves symlinks, permissions and
signatures) and remove `com.apple.quarantine` if the download API set it. We
never modify or re-sign the emulator tree.

### 3.5 Swift toolchain facts

- `grpc/grpc-swift-2` 2.4.x (`GRPCCore`), `grpc/grpc-swift-nio-transport` 2.9.x
  (`GRPCNIOTransportHTTP2`), `grpc/grpc-swift-protobuf` 2.x (`GRPCProtobuf`),
  `apple/swift-protobuf` 1.31+. All three gRPC packages require macOS 15.0,
  which is our deployment target.
- The NIO transport's default maximum message size is 4 MiB. A 1080×2400
  RGBA frame is 10.4 MB, so the limit is raised to 256 MiB (covering 7680×7680 RGBA) in the
  `CallOptions` of every screenshot call. Spike finding: in
  grpc-swift-nio-transport 2.9 the inbound decoder takes its cap from
  **`maxRequestMessageBytes`**, not `maxResponseMessageBytes`, so both are
  set.
- Measured throughput (Release build, spike item 10): ~50 fps at 1080×2400
  over plain gRPC (520 MB/s) with the client on ~15–20 % of one core. Debug
  builds decode 3–5× slower; profile only Release.
- `withGRPCClient` is scoped and shuts the client down when its closure
  returns; the app needs a client that outlives any call, hence the
  `EmulatorConnection` wrapper (§4).
- Code generation uses the `protoc-gen-swift` and `protoc-gen-grpc-swift-2`
  executables built once with SwiftPM (`Tools/protoc-plugins`) and Homebrew's
  `protoc`; output is committed under `MandroidKit/Generated/`. The
  `GRPCProtobufGenerator` build plugin is deliberately not used because it does
  not compose well with an xcodegen-generated Xcode project.

## 4. Architecture

Two targets plus tests, generated by xcodegen (`project.yml`), following the
conventions of the author's other macOS apps (macOS 15, Swift 6 language mode,
framework + app, hardened runtime in Release).

```
mandroid/
  project.yml
  Protos/emulator_controller.proto        vendored, with a PROVENANCE note
  Scripts/gen-proto.sh                    regenerates MandroidKit/Generated
  Scripts/integration-test.sh             needs a booted emulator
  Tools/protoc-plugins/Package.swift      pins and builds the two protoc plugins
  Tools/Spike/                            Phase 0 throwaway executable
  MandroidKit/                            framework, no AppKit UI
    Generated/                            *.pb.swift, *.grpc.swift (committed)
    SDK/        SDKPaths, RepositoryManifest, Downloader, Unarchiver, SDKBootstrap, AAPT2Fetcher
    AVD/        AVDConfig, AVDStore
    Emulator/   EmulatorProcess, EmulatorLaunchOptions, PortAllocator, BootWaiter, GuestSetup
    ADB/        ADBClient, DumpsysDisplayParser, PackageListParser
    Client/     EmulatorConnection, EmulatorClient
    Display/    DisplaySlotPool, DisplaySlot, AppSession
    Frames/     Frame, FrameStream (protocol), GRPCFrameStream
    Input/      InputChannel, InputRouter, CoordinateMapper, KeyMap
    Catalog/    InstalledApps, APKBadging, IconExtractor, AppInstaller, AppCatalogCache
    Clipboard/  ClipboardSync
    Notifications/ NotificationStream
    Runner/     RunnerCoordinator, RunnerState
  Mandroid/                       app target
    AppDelegate.swift, Info.plist, Assets.xcassets
    Setup/      SetupWindow (SwiftUI onboarding, download progress)
    Library/    LibraryWindow, LibraryViewModel, APKDropTarget
    AppWindow/  AppWindowController, FrameView, InputHandler, ParkedOverlayView
    Device/     DeviceScreenWindowController (display 0)
    Menu/       MainMenu
    Launchers/  LauncherStubBuilder, URLSchemeHandler
    Settings/   SettingsView
    WindowManager.swift, ResizeCoordinator.swift
  MandroidKitTests/  + Fixtures/ (manifest excerpts, dumpsys dumps, aapt2 output)
```

### 4.1 Module responsibilities

**SDK/** — `RepositoryManifest` parses `repository2-3.xml` and `sys-img2-3.xml`
with `XMLParser` into packages → archives, selecting channel-0 (stable),
`host-os == macosx` and the current `host-arch`. `Downloader` uses
`URLSession` download tasks with resume data, progress and SHA-1 verification.
`Unarchiver` shells out to `ditto`. `SDKBootstrap` turns a desired component
set into an idempotent plan (skip completed components, verify on relaunch).
`SDKPaths` owns the directory layout under Application Support.
`AAPT2Fetcher` resolves a pinned aapt2 version from Google Maven and extracts
the binary.

**AVD/** — `AVDConfig` is a value type rendered to `config.ini`; `AVDStore`
writes the pointer `.ini` and the `.avd` directory under `ANDROID_AVD_HOME`.

**Emulator/** — `EmulatorProcess` spawns
`emulator -avd runner -qt-hide-window -grpc <port> -no-boot-anim -gpu host -feature Vulkan`
with the isolated environment, captures stdout/stderr to
`<dataRoot>/logs/emulator-<timestamp>.log`, and shuts down via
`setVmState(SHUTDOWN)` with a SIGTERM fallback. `PortAllocator` picks a free
even console port (5554 + 2n; adb serial is `emulator-<port>`) and a gRPC
port. `BootWaiter` waits for adb and `sys.boot_completed=1`. `GuestSetup`
applies guest settings after each boot. Normal sessions save quickboot state
at shutdown; KernelSU sessions disable snapshot loading and saving. The
coordinator flushes guest filesystem writes before requesting shutdown.

**ADB/** — `ADBClient` is an async wrapper around the bundled `adb`
(`-P <server port> -s emulator-<console>`), with typed commands (`shell`,
`install`, `pull`, `forward`) and no string interpolation of untrusted
arguments. `DumpsysDisplayParser` and `PackageListParser` are pure functions
with fixture-based tests.

**Client/** — `EmulatorConnection` runs `withGRPCClient` in a long-lived task
and publishes the client; `EmulatorClient` is the typed facade
(`displays()`, `setDisplays(_:)`, `frames(display:size:)`, `input`,
`clipboard`, `notifications()`, `status()`, `shutdown()`), exposing streams as
`AsyncThrowingStream`.

**Display/** — `DisplaySlotPool` owns slots 1–3. `acquire(size:dpi:)` assigns
a slot, pushes the full display set via `setDisplayConfigurations`, re-reads
`dumpsys display` and returns a
`DisplaySlot{emulatorIndex, androidDisplayId, pixelSize, dpi}`. The join key
is deterministic (spike item 3): emulator display *N* shows up in Android
with `uniqueId="virtual:com.android.emulator.multidisplay:123456<N+1>"`;
the logical `displayId` is not stable across reboots and is re-read every
time. On startup the pool always pushes an **empty** secondary set first,
because the emulator writes `hw.displayN.*` into the AVD `config.ini` and
would otherwise recreate stale displays. `release` removes the display.
Phase 2 adds LRU parking (§5.5). `AppSession` ties a package, a slot and a
window together.

**Frames/** — `FrameStream` is a protocol so the transport can change without
touching the UI: `GRPCFrameStream` consumes `streamScreenshot`. The MMAP
transport was dropped after the spike (item 6: it crashes emulator 36.3.10);
the protocol stays for a future scrcpy-style provider.

**Input/** — `InputChannel` owns the single `streamInputEvent` bidirectional
stream. `CoordinateMapper` converts view points to display pixels (letterbox
and scale aware). `KeyMap` converts `NSEvent` to `KeyboardEvent`.
`InputRouter` implements the keyboard-focus policy (§5.4).

**Catalog/** — `InstalledApps` (`pm list packages -3`, `pm path`, version
codes), `APKBadging` (`aapt2 dump badging` on pulled APKs → label, icon
entries), Android `RenderAppIcon` (resolves the launcher activity icon and renders
adaptive/vector/split resources to PNG), `IconExtractor` (best-effort raster
fallback if guest rendering fails), `AppInstaller`
(`adb install`), `AppCatalogCache` (disk cache keyed by package + versionCode,
with an icon strategy version so legacy or missing icons are refreshed).

**Runner/** — `RunnerCoordinator` is a `@MainActor` observable state machine:
`needsSetup → downloading → booting → ready → error`, owning the process, the
connection, adb and the slot pool. The UI binds to it.

### 4.2 App target

`AppDelegate` (AppKit lifecycle; last window closed does not quit; handles
`mandroid://launch/<pkg>` URLs), `SetupWindow` (SwiftUI onboarding with
component sizes and download progress), `LibraryWindow` (SwiftUI grid: search,
open, Play Store, install APK by drag and drop, uninstall),
`AppWindowController` (one `NSWindow` per running app, title = app label),
`FrameView` / `MetalFrameView` (rendering, §5.2), `InputHandler` (event
translation, §5.3), `DeviceScreenWindowController` (display 0 for Play sign-in,
permission dialogs and troubleshooting), `WindowManager` (focus nudging,
Window menu), `MainMenu`, `LauncherStubBuilder` + `URLSchemeHandler`
(§5.7), `SettingsView`, `ResizeCoordinator` (§5.6).

Info.plist: no App Sandbox (we spawn processes and read the SDK tree);
`NSSupportsAutomaticTermination` and `NSSupportsSuddenTermination` are false
so macOS never kills us out from under a running QEMU; `CFBundleURLTypes`
registers `mandroid`; not `LSUIElement` (we own real windows).

## 5. Key mechanisms

### 5.0 Field notes from the first end-to-end run

- Start the adb server (`adb start-server` on our port) **before** launching
  the emulator. The emulator's own adb helper calls time out while a fresh
  server enumerates USB (~10 s on the test Mac) and each timed-out call forks
  another server, which then fight for the port.
- Gboard shows a "Try out your stylus" sheet on display 0 the first time a
  field gets focus and swallows every key; `stylus_handwriting_enabled 0` in
  `GuestSetup` prevents it. Anything the system puts on display 0 is one click
  away in the Device Screen window.
- Never hand the app a path under `/Volumes/…`: reading it blocks on macOS's
  removable-volume permission dialog, and LaunchServices then also stalls
  registering bundles from that volume.
- After a park/resume cycle (task moved to display 0 and back) some apps stop
  accepting text input until reopened (`docs/compat.md`).

### 5.1 Lifecycle

1. **Setup** (`needsSetup`): show what will be downloaded and how big it is
   (≈ 2.4 GB), the license notice, and the system image choice. Download,
   verify, extract, write `licenses/`, write the AVD. No `platforms/` directory
   is needed (§3.4).
2. **Boot**: spawn the emulator, wait for adb, wait for
   `sys.boot_completed`, apply guest settings
   (`settings put secure show_ime_with_hard_keyboard 0`,
   `svc power stayon true`, animation scale 1.0). When KernelSU is enabled,
   prepare the verified ramdisk before launch and verify the module after
   boot. Normal sessions may load quickboot state; display/GPU/boot-mode
   changes skip it. KernelSU sessions always cold boot.
3. **Ready**: library window, catalog refresh, device-screen window on demand.
4. **Open app**: acquire a slot → `am start --display <androidId> -n
   <component>` where the component comes from
   `cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <pkg>`
   → window subscribes to frames.
5. **Close window**: `am force-stop <pkg>` (or keep the task alive when
   parking), release the slot. The emulator stays warm after the last window
   closes; the app quits only from the menu, shutting the emulator down
   cleanly.

### 5.2 Rendering

- Frames are requested as **RGBA8888**. RGB888 saves a quarter of the bytes
  but its rows are not 4-byte aligned and no Core Animation or Metal format
  matches it, so every frame would need a CPU repack.
- Build a `CGImage` over the frame bytes (`CGDataProvider`,
  `byteOrder32Big | noneSkipLast`) and set it as `layer.contents`. Rows are
  top-down (spike item 7), no flip. The emulator only emits a frame when
  content changes and `Image.seq` gaps tell us about drops; a frame that
  arrives while the previous one is still being committed is dropped.
- The virtual display is sized to the window's **physical** pixels with
  `dpi = 160 × backingScaleFactor`, which makes 1 dp = 1 pt and gives
  Retina-crisp rendering, and frames are requested at that same size. The
  spike measured ~50 fps at 1080×2400 over gRPC, so no shared-memory path is
  needed. A `CAMetalLayer` blit remains an option if CGImage upload ever
  shows up in profiles.

### 5.3 Pointer input

- Delivered as `TouchEvent` over the `streamInputEvent` stream. Phone images
  treat `MouseEvent` as a real mouse (visible guest cursor, hover states) and
  touch-only apps often ignore it.
- Mouse down → `Touch{x, y, identifier: 0, pressure: 1000}`; drag → same
  identifier, new coordinates; mouse up → **same identifier, `pressure: 0`**
  (otherwise the touch identifier leaks; the default `expiration` self-heals a
  lost up-event after 120 s). Click-and-hold is a long-press with no special
  handling.
- Mouse-wheel and trackpad scrolling → Android mouse `ACTION_SCROLL`
  (`SOURCE_MOUSE`) on the window's logical display, injected by the
  long-running `ScrollInjector` guest helper (see "Secondary-display input
  method routing"). `ScrollChannel` feeds it one line per event over a single
  `adb shell` and restarts it if it dies. The emulator's `injectWheel` is
  dropped on the phone image, and the only way to get a wheel device
  (`-feature VirtioMouse`) removes the per-display touch devices and must never
  be enabled.
- Scroll is never a touch. A synthesised drag becomes a click wherever no
  scroll container intercepts it: content that fits, a horizontal swipe over a
  vertical list row, a ViewPager below its 16 dp paging slop. Views cancel a
  click only on a parent's `ACTION_CANCEL` or when the finger leaves their
  bounds, and the emulator touch API cannot send a cancel. Scrolling does not
  move keyboard focus either.
- `ScrollConverter` maps a wheel line to one Android notch (axis 1.0 = the
  stock 64 dp `config_verticalScrollFactor`). Precise trackpad deltas become
  display pixels divided by that factor, so standard scroll containers track
  the fingers 1:1. Only whole pixels are sent; RecyclerView truncates
  `axis × factor`, so the remainder carries over and a 0.01 px bias absorbs
  float error. macOS momentum events supply the fling. Views that ignore
  `ACTION_SCROLL` (e.g. a Material collapsing app bar, pull-to-refresh, the
  legacy ViewPager) do not react, as with a physical mouse on Android.
- Right-click is unmapped by default.

### 5.4 Keyboard and focus

`KeyboardEvent` has no display id and Android has one keyboard focus
device-wide, so `InputRouter` implements a policy ladder:

0. Android routes keys to `FocusedDisplayId` (`dumpsys input`), which is the
   last display that received a touch (spike item 5). `InputRouter` tracks
   the display of the last touch we sent, so typing after a click needs no
   extra work. `OWN_FOCUS` was tested and changes nothing here.
1. On `windowDidBecomeKey`, if the last touched display differs, nudge with
   `am start --display <id> -n <launcher component>` of that window's app
   (the task is already at the top of that display, so Android only moves
   focus, "intent delivered to top-most instance"). A `MouseEvent{buttons: 0}`
   hover does not move focus on the phone image.
2. Use `TextViewFocus{textViewHasFocus, display}` from `streamNotification`
   as ground truth for where Android thinks text focus is; the window UI can
   show a subtle "keyboard not focused" state.
3. Accelerators (Back, Home, Recents) can go through
   `adb shell input -d <displayId> keyevent …`, which is display-targeted but
   costs 50–100 ms per call and is unusable for typing.
4. If step 1 fails outright, the policy becomes "one keyboard-focused window
   at a time" without any other change.

Key mapping: printable characters as `text`; `Enter`, `Backspace`, `Tab`,
`Escape`, arrows, `Delete` as DOM `key` names; ⌘[ and Esc → `GoBack`;
⇧⌘H → `GoHome`; ⌘W closes the window; ⌘C/⌘V/⌘X are forwarded as Ctrl-key
combinations to Android text fields (clipboard content itself flows through
clipboard sync).

### 5.5 Display slot pool and parking

Three slots per emulator. Phase 1 refuses a fourth window with a clear
message. Phase 2 parks the least-recently-used window instead: its last frame
is frozen behind a dimmed "Click to resume" overlay, its slot is released and
its Android task keeps living; resuming acquires a slot and runs
`am start --display <newId>` for the task (a resume, not a cold start, as long
as the process survived). A second emulator instance is the explicit,
user-initiated escape hatch for more windows (about 2 GB RAM each).

### 5.6 Resizing

App windows resize freely with a minimum content size of 320×320 points.
During dragging, coalesce changes every 150 ms and reconfigure the guest
display in place at the window’s physical pixel size and backing density.
Only one update runs at a time; subsequent changes apply the latest size.
Restart the screenshot stream and update input coordinates after Android
reports the new resolution. Restored window sizes and monitor changes use
the same path. Device Screen retains its fixed guest resolution. Apps that do not
declare `configChanges` are destroyed and recreated by Android on a
configuration change; that is their normal behaviour and is documented in the
compatibility matrix.

### 5.7 Launcher stubs (Dock and Spotlight presence)

For each catalogued app, generate
`~/Applications/Android Apps/<Label>.app`: a minimal bundle with an `.icns`
built from the extracted icon and an executable that runs
`open "mandroid://launch/<pkg>"`. The runner handles the URL, boots if
needed, and opens the app window. Stubs are regenerated when the catalog
changes and removed on uninstall.

### 5.8 Clipboard

`ClipboardSync` polls `NSPasteboard.changeCount` and subscribes to
`streamClipboard`; each direction remembers a hash of the last value it wrote
and drops echoes so the two systems never ping-pong.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Uncompressed frames over gRPC at Retina sizes | Measured 50 fps at 1080×2400 in Release; drop stale frames; pause streams for hidden windows |
| Keyboard has no display target | Focus nudge on activation, `TextViewFocus` as ground truth, single-keyboard-window fallback |
| Hard cap of 3 displays | Slot pool with LRU parking; "3 of 3 windows in use" UI; future providers |
| App compatibility on secondary displays (`resizeableActivity=false`, display-0 assumptions) | Per-app "run on device screen" fallback; compatibility matrix; manifest warning |
| Permission or system dialogs appearing on display 0 | Device-screen window one click away; detect foreground change on display 0 and prompt |
| Emulator startup time | Quickboot snapshot after guest setup; keep the emulator warm; status UI |
| 2.4 GB first-run download | Resume + SHA-1, sizes disclosed up front, image choice |
| grpc-swift 2 ergonomics under Swift 6 strict concurrency | `EmulatorConnection` wrapper, `AsyncThrowingStream` facades, per-method message-size config |
| Gatekeeper / hypervisor entitlement on a downloaded emulator | Keep Google's signature intact (ditto), strip quarantine, verify in spike |
| Play Integrity apps | Stated limitation, surfaced in the library |

## 7. Future directions (out of scope)

- **Android-side display provider**: a downloaded prebuilt `scrcpy-server`
  (Apache-2.0) creating guest virtual displays and streaming H.264 decoded by
  VideoToolbox. Lifts the 3-display cap and the bandwidth ceiling; slots in
  behind `FrameStream` and the slot pool.
- **Second emulator instance** for more windows.
- **`android-desktop` system image** (freeform windowing, API 34, no Play
  Store) as plan B if virtual-display compatibility proves poor across apps.
- Physical devices over adb using the same provider abstraction.


### Secondary-display input method routing

Before launching an app, set its display's IME policy to LOCAL. The default
fallback to display 0 allows Gboard to consume hardware keys without updating
Bilibili's Compose phone-number field. This was reproduced with both emulator
key events and `adb input`, and corrected by binding Gboard to the editor's
display before launch.

The macOS app remains Swift. A dependency-free Java `app_process` helper is a
small exception to the original Swift-only implementation: it calls the guest
framework's IWindowManager proxy by reflection. This avoids unstable hard-coded
Binder transaction numbers. It requires no APK install, root, or background
service. Its source is in `Tools/guest-display`, and its generated DEX JAR is
bundled in MandroidKit. Rebuild with `Scripts/gen-guest-display.sh` (JDK 17 and
`D8` pointing to Android build-tools 36.1.0, and `ANDROID_JAR` pointing to
an installed platform android.jar). The same JAR includes `RenderAppIcon`,
which loads the launcher activity icon through Android PackageManager and
renders it to PNG, and `ScrollInjector`, which stays running and turns
`display x y vscroll hscroll` lines on stdin into mouse `ACTION_SCROLL`
events through `InputManagerGlobal.injectInputEvent`. Runtime users need no
Java or Android build tools.

### Native media volume

Settings reads Android's STREAM_MUSIC range and controls its volume through the
bundled `SetMediaVolume` app_process helper. The helper calls the guest's native
AudioService with `com.android.shell`, matching its shell UID. The media_session
shell command can silently ignore changes attributed to its server package on
the current image, so the setter also verifies the applied volume. The selected
percentage is persisted only after a successful change and restored after boot.
No audio streaming or host-side playback is added.

Mandroid's private ADB environment sets `ADB_USB=0`: only emulator transports are
needed, and physical USB enumeration can stall in IOKit during desktop launches.

### Per-app HTTP proxy settings

The library's HTTP Proxy sheet stores independent host/port endpoints by Android
package in `<root>/app-proxies.json`. Localhost endpoints use the emulator's
`10.0.2.2` alias to reach a proxy on the Mac. The host reapplies settings after
boot and package changes and waits for a revision-specific acknowledgement.

A bundled, signed Android APK (`Tools/proxy-agent`) uses the public
`VpnService.Builder.addAllowedApplication` and `setHttpProxy` APIs to recommend a
loopback HTTP proxy only to configured apps. Its listener looks up the client
UID with `ConnectivityManager.getConnectionOwnerUid`, then bridges that
connection to the corresponding upstream HTTP proxy. HTTP and HTTPS CONNECT
bytes are forwarded without TLS interception. Unknown UIDs are rejected;
shared-UID apps cannot be assigned conflicting endpoints. The helper is hidden
from the library, and only the Android shell/system can access its configuration
activity and status provider (the DUMP permission).

This is an HTTP proxy setting, not a forced tunnel for arbitrary app traffic.
Apps that ignore Android's proxy recommendation remain direct. No IP routes are
captured, and apps outside the allowed list retain their normal network.
Android provides one VPN connection per user, so this feature replaces another
Android VPN if one is active. See the [Android VPN proxy API](https://developer.android.com/reference/android/net/VpnService.Builder#setHttpProxy(android.net.ProxyInfo)).

Rebuild the APK using `Scripts/gen-proxy-agent.sh` with JDK 17, `ANDROID_JAR`,
`ANDROID_BUILD_TOOLS`, `KEYSTORE_PATH`, `KEY_ALIAS`, and `KEYSTORE_PASSWORD`.
Use the same signing key for upgrades. Runtime users need no Android build tools.

### Optional KernelSU ramdisk

`KernelSUPatcher` prepares a copy of the supported stock ramdisk under
`boot-patches/kernelsu` in the selected data root. KernelSU 3.3.0 assets are
pinned by SHA-256 and verified before execution. CryptoKit is supplied by
macOS; no package dependency is added. Kernel compatibility is checked against
the actual decompressed kernel version, including its build and page size.

The cache key includes the stock kernel and ramdisk hashes; a manifest verifies
the patched ramdisk and extracted guest helper before reuse. Failed or cancelled
preparation removes staging files. SDK image files are never patched in place.
The coordinator owns one preparation task shared by Settings and boot and
cancels/drains it at shutdown. Tool execution has a two-minute timeout.

Rooted launches use `-ramdisk` and `-no-snapshot`. Shutdown runs guest `sync`
before QEMU exits so recent filesystem writes survive the next cold boot.
The AVD root-mode marker forces a cold boot when returning to stock,
preventing an old snapshot from restoring
a different boot mode. Guest data and installed apps remain in the same AVD.
After boot, the guest helper verifies kernel version code 32601, and the official
Manager is installed if absent and opened to initialize userspace. Shell root
is not pre-authorized. The default setting is off.
