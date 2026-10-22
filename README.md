<p align="center">
  <img src="Mandroid/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="Mandroid app icon">
</p>

# Mandroid

English | [简体中文](README.zh-CN.md)

Run Android apps on your Mac as if they were native macOS apps. Each Android
app gets its own window with a normal title bar, resizes like a Mac window,
shares the clipboard, answers to Cmd shortcuts, and shows up in the Dock and
Spotlight — no phone frame, no Android status or navigation bars.

**Status: working prototype.** The core workflows from phases 0–3 are implemented and
exercised end to end (first-run download, boot, app windows with touch,
keyboard, scroll, free resize, clipboard, launcher stubs). Signed and
notarized builds are on the [Releases](https://github.com/madeye/mandroid/releases)
page; you can also build from source. The design and the phased plan live in
[`docs/`](docs/):

- [docs/DESIGN.md](docs/DESIGN.md) — architecture, verified facts, mechanisms, risks
- [docs/PLAN.md](docs/PLAN.md) — phases with "done when" criteria and status
- [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md) — measurements behind the design decisions
- [docs/compat.md](docs/compat.md) — per-app compatibility and display-profile testing
- [docs/KERNELSU.md](docs/KERNELSU.md) — optional root support, supported image, and recovery

## Building

```bash
brew install xcodegen protobuf   # protobuf only if you regenerate gRPC code
xcodegen generate
xcodebuild -scheme Mandroid -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Mandroid-*/Build/Products/Debug/Mandroid.app
```

On first launch the app lists what it will download (about 2.5 GB from
`dl.google.com`) and installs everything under
`~/Library/Application Support/Mandroid/`. On Macs set to mainland China the
download comes from the Tencent Cloud mirror instead (Aliyun for aapt2); the
choice can be changed on the setup screen or in Settings ▸ Downloads.

## How it works

The app downloads the stock Android Emulator, platform-tools and a Google Play
system image on first launch and boots the emulator headless. For every
Android app you open it creates a private virtual display inside the emulator,
launches the app on that display, and streams the display's pixels into a
macOS window over the emulator's gRPC API. The built-in device uses a
Pixel Tablet-sized 2560×1600 display at 320 dpi; app windows render at their
own physical pixel size and reconfigure Android when resized. New windows
default to 1280×800 points (2560×1600 pixels on a 2× Retina screen), scaled
down to fit smaller screens. Mouse, keyboard, scroll and
clipboard are translated back the same way.

## Settings

Settings (⌘,) includes a media-volume slider for all Android apps. It controls the
guest's native media stream, supports mute, and restores your chosen level on
restart. Audio continues to play through the emulator's native macOS backend.

For layout compatibility testing, Settings ▸ Virtual device ▸ Device screen
profile offers Tablet (1280×800 dp), Phone (400×900 dp), Compact phone
(360×640 dp), and Custom. Presets use 320 dpi; Custom supports width and
height from 320–1600 dp and density from 120–480 dpi. Restart Emulator applies
display changes with a cold boot and preserves installed apps and data.
Open Device Screen and launch the Android app there to test the selected
profile. Separate app windows continue to follow their own window geometry.
Profiles configure display geometry; Android device identity and attestation
remain those of the stock emulator image.

Settings ▸ KernelSU (experimental) can prepare a separate patched ramdisk and
boot with root support. It is off by default. Enable **Boot with KernelSU**,
then **Restart to Apply**. The first rooted boot downloads and verifies
KernelSU 3.3.0 and installs its Manager if needed.
You can also prepare the image ahead of time with **Prepare Patched Image**.
The supported image is Android 36.1 ARM64 revision 4 with kernel
`6.12.38-android16-5-gbb9513914902-ab13996879-4k`; other kernels are rejected.
Rooted sessions cold boot. Turn KernelSU off and restart to boot stock while
keeping installed apps and data. Manage root grants in KernelSU Manager;
KernelSU alone does not grant root to the ADB shell; the capture certificate
feature is what prepares a shell-root ramdisk. See [KernelSU settings](docs/KERNELSU.md).

Settings ▸ Camera & Microphone lets Android apps use this Mac's camera (as the
front camera) and microphone, for voice and video calls. Both are off by
default; macOS asks for permission the first time an app records. Restart
Android after changing them.

Settings ▸ Virtual device defaults to hardware graphics with Vulkan descriptor
batching, with the original hardware, automatic, and software profiles available.
Restart Android after changing the backend;
existing app data is preserved. See [GPU benchmarks](docs/GPU-BENCHMARKS.md) for
the measurement protocol and backend results.

## Requirements

- A Mac with Apple silicon (M1 or later) running macOS 15 or later. Intel
  Macs are not supported; the app is built for arm64 only.
- About 2.5 GB of disk for the emulator and system image, downloaded on first
  launch, plus space for Android apps and data
- No Java, Android Studio or SDK installation needed

## Limitations

- At most three Android app windows at a time per emulator instance (an
  emulator limit); additional windows are parked and resume on click
- Apps that require Play Integrity attestation (many banking and DRM apps)
  are unsupported; enabling KernelSU does not provide a passing verdict

## Roadmap

See [docs/PLAN.md](docs/PLAN.md) for implementation status and remaining work.
Future candidates include an Android-side display provider to lift the
three-window cap, a second emulator instance, and a macOS notification bridge.

## Offscreen UI tests

Build Debug, then run the real-emulator smoke test with an APK:

```sh
python3 Scripts/run-ui-tests.py --app /path/to/Mandroid.app --apk /path/to/app.apk --package com.example.app
```

For the volume controls alone, use `--test volume` instead of `--apk` and
`--package`. This checks mute, full volume, and midpoint volume through the
same native Android control path as Settings, then restores the previous level.

The launcher uses fresh guest data in `~/Library/Caches/mandroid-ui-*`, reuses
Mandroid's installed SDK and tools, and shuts down its own process afterward.
Windows stay hidden; input and resize commands use a private file queue.
The test checks rendered frames, guest resolution, display cleanup, and zero
visible windows. Screenshots and logs remain in the printed artifact directory.
Python Pillow is required for the frame check. The Debug-only mode disables
clipboard sharing and launcher creation, leaving the normal app session alone.

## Local audit workflow

Run `Scripts/audit.sh` to build Debug and Release, run unit tests, check script
syntax, and verify generated protobuf sources. Add
`--apk /path/to/app.apk --package com.example.app` for isolated real-emulator
checks, including repeated launches and closing a parked window after its
display is reused. See [the audit report](docs/AUDIT.md) for findings and scope.

## License

MIT — see [LICENSE](LICENSE).

## Upgrading from Madroid

Quit Madroid before opening Mandroid. On first launch, Mandroid moves the
existing SDK, Android virtual device, installed apps, and icon cache from
`~/Library/Application Support/Madroid` to `~/Library/Application Support/Mandroid`
and copies your preferences. Android App Runner installations are also supported.
Existing Mandroid data is never overwritten. Old `madroid://` links still work,
and generated app launchers are updated to use `mandroid://`.

## Per-app HTTP proxies

Right-click an app in the library and choose **HTTP Proxy…**. Enable the proxy,
enter its host and port, and save. Each app can use a different proxy at the
same time. Use `localhost` for a proxy running on your Mac. Settings survive
restarts; turning off one app's proxy leaves the others configured.

This configures Android's HTTP proxy recommendation, including HTTPS CONNECT.
Apps that ignore Android HTTP proxy settings remain direct. The helper uses
Android's VPN connection, replacing any other active Android VPN. No TLS
certificates are installed and encrypted traffic is not decrypted.

## Capture certificates

Settings ▸ Capture certificates installs a debugging proxy's root CA into the
virtual device's system trust store, so apps trust the HTTPS traffic the proxy
captures. Choose the proxy's certificate file or paste its PEM, or enter the
proxy's host and port and fetch the CA from it; Mandroid shows the subject and
validity before installing, and with a proxy configured it first checks that
the proxy signs with the chosen CA. Installing needs a rooted session, in one of
two shapes. With KernelSU, turn on **Boot with KernelSU** and the capture
certificate switch, then restart: the two together are what prepare a
shell-root ramdisk. Otherwise boot a `google_apis` image with **Boot with a
writable system partition**, whose store Mandroid rebuilds whenever the emulator
starts. Chrome verifies against its own root store and ignores the installed CA,
and apps that pin their own certificate still fail.
See [Certificate injection](docs/CERTIFICATE-INJECTION.md).
