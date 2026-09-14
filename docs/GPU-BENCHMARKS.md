# GPU backend measurements

Measurements use an unmodified official [3DMark Android](https://benchmarks.ul.com/3dmark-android) installation. Scores measure this emulator configuration on this Mac; they are not native Android hardware scores.

## Protocol

- Apple M4 (10 GPU cores), 32 GiB RAM, macOS 26.6.2 (25G83).
- Android Emulator 37.1.11.0 (15917651), Android 16 / API 36.1 Google Play arm64 image (`BE4B.251210.005/14574095`).
- Guest: 4 CPU cores, 4096 MiB RAM, 2560 × 1600 display at 320 dpi.
- 3DMark 2.7.5093 from UL's official APK download. SHA-256: `c8db033f7f3e14b202745e6ae72b840cedfd5489fd2094fcc93c13438230ff2c`.
- Wild Life and Wild Life Unlimited use Vulkan at their fixed 2560 × 1440 render resolution. Sling Shot Unlimited uses OpenGL ES 3.0 at its fixed 1920 × 1080 render resolution. The regular on-screen test maxed out at approximately 60 FPS and cannot rank these hardware backends. Unlimited is a separate comparison; do not compare its score with the regular test.
- One emulator runs during measurement. Cold boot when changing backends, retain benchmark assets and user data, and disable snapshot loading/saving for the experiment.
- Freeze guest background updates before measurement: disable Play Store in the isolated AVD and disable Wi-Fi/cellular networking after all assets are installed. Record the installed Play services version. An exploratory run was invalidated by a background Play services update; it is excluded from the controlled series.
- Disable the unscored demo consistently for all controlled runs. Benchmark workloads and quality remain unchanged.
- Perform a separate warm-up and visual check, then three uninterrupted runs. Report the median and range, retaining failed runs. Do not change resolution, quality, device identity, or correctness checks to improve scores.
- Capture results after rendering finishes. No screen recording, build, or additional GPU workload was started by the benchmark workflow during measured runs. This was a live desktop: unrelated background services and browsers remained running, so host contention was not eliminated. Retain thermal status and renderer identification with the scores.

## Launch profiles

All profiles use `-feature Vulkan` and identical AVD resources. Use the emulator's own `-help-gpu` output to check the installed version's supported modes.

| Profile | GPU mode | Additional configuration |
| --- | --- | --- |
| Default hardware | `host` | none |
| Metal hardware | `host` | `ANDROID_EGL_ON_EGL=1`, `ANGLE_DEFAULT_PLATFORM=metal` |
| Emulator automatic | `auto` | none |
| Vulkan descriptor batching | `host` | add `VulkanBatchedDescriptorSetUpdate` to `-feature` |
| Asynchronous MoltenVK submissions | `host` | `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0` |
| MoltenVK command prefill | `host` | `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` |
| Software control | `software` | none |

A name is not proof of hardware acceleration. Inspect the emulator log's `Selecting Vulkan device` and `Graphics Adapter` entries, and `adb shell dumpsys SurfaceFlinger`'s `GLES:` line. In particular, legacy `angle` mode names may be redirected to software by the emulator. The Metal profile above reported `ANGLE Metal Renderer: Apple M4`, but shader compilation failed and both benchmark scenes and result screenshots were entirely black. It is rejected and is not offered in Settings. Its internal score is not an eligible performance result.

MoltenVK parameters are documented by [Khronos](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Configuration_Parameters.md). They are experimental benchmark candidates, not assumed performance improvements.

## Reproduce

Use a dedicated AVD named `gpu-benchmark` in a separate data directory. Copy only the normal AVD's `config.ini` to `avd/gpu-benchmark.avd/config.ini`, change `AvdId`, remove persisted `hw.displayN.*` entries, and create the AVD pointer file. Do not copy live userdata or snapshots. Set `ANDROID_AVD_HOME` and `ANDROID_EMULATOR_HOME` to this isolated directory and use the installed Mandroid SDK through `ANDROID_SDK_ROOT` / `ANDROID_HOME`.

Launch with separate console, ADB server and gRPC ports, for example:

```sh
# Set SDK and BENCH to the SDK and isolated benchmark directory first.
ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK" \
ANDROID_AVD_HOME="$BENCH/avd" ANDROID_EMULATOR_HOME="$BENCH/emulator-home" \
ANDROID_ADB_SERVER_PORT=5141 ADB_USB=0 \
"$SDK/emulator/emulator" -avd gpu-benchmark -port 5570 -grpc 8570 \
  -no-window -no-boot-anim -no-metrics -no-snapshot -gpu host -feature Vulkan
```

Record the exact command, emulator version and GPU environment for each profile. Clear previous profile overrides before launching the next one. Wait for `sys.boot_completed=1`, install the official APK with ADB, and download Wild Life and Sling Shot in 3DMark. Close the normal Mandroid app before measuring. Open 3DMark's English benchmark selection screen with the requested test tab visible, then run:

```sh
python3 Scripts/benchmark-gpu.py \
  --adb "$SDK/platform-tools/adb" --adb-port 5141 --serial emulator-5570 \
  --output "$BENCH/results" --profile host --test 'WILD LIFE' --unlimited --runs 4
```

The script verifies the AVD name and saves device information, thermal state, full result text, XML and PNGs. It stops on missing numeric scores or a timeout; a timeout is not permission to restart an emulator whose benchmark is still running. A maxed-out result must be reported as such, not converted into an invented score.

The command runs one warm-up followed by three measured repetitions; exclude the first result from the reported median. For Sling Shot Unlimited, replace the test name with `SLING SHOT`. The script rotates the selection screen to portrait because 3DMark hides its variant selector in the landscape layout. This changes the selection UI orientation, not the benchmark render resolution. Keep the same orientation for every profile.

## Results

All numeric comparisons below use the controlled offline, no-demo conditions above. Each series excludes its first warm-up and reports three measured runs. Raw result text and evidence hashes are in [gpu-benchmark-results.json](gpu-benchmark-results.json).

### Wild Life Unlimited (Vulkan)

| Profile | Measured scores | Median | Median FPS | Versus default median |
| --- | --- | ---: | ---: | ---: |
| Default hardware | 17,532 / 17,263 / 17,546 | 17,532 | 104.99 | baseline |
| Descriptor batching | 17,825 / 17,612 / 17,711 | 17,711 | 106.06 | +1.02% |
| Asynchronous submissions | 17,501 / 17,548 / 17,195 | 17,501 | 104.80 | −0.18% |
| Command-buffer prefill | 17,433 / 17,481 / 17,534 | 17,481 | 104.68 | −0.29% |

A second cold-boot series repeated the baseline followed by batching:

| Profile | Measured scores | Median | Range |
| --- | --- | ---: | --- |
| Default hardware | 17,566 / 16,872 / 17,655 | 17,566 | 16,872–17,655 |
| Descriptor batching | 17,624 / 17,766 / 17,861 | 17,766 | 17,624–17,861 |

Batching led by **1.14%** in the confirmation series. Across all six measured runs per profile, the medians were 17,738.5 versus 17,539 (+1.14%). The highest individual batching score was **17,861**. This is a modest local result with overlapping run ranges, not evidence of a large or universal speedup. All runs, including the lower second-series baseline, are retained.

### Other measurements and exclusions

- Controlled regular Wild Life on the default backend: 8,534 / 8,683 / 8,511, median **8,534**. Descriptor batching returned **Maxed Out!** in this variant; that result has no eligible numeric score.
- Controlled Sling Shot Unlimited on the default backend: 15,442 / 15,583 / 15,702, median **15,583**. Batching: 15,495 / 15,234 / 15,208, median **15,234** (−2.24% overall). Graphics medians were 36,391 versus 36,058 (−0.92%); physics medians were 5,232 versus 5,077 (−2.96%). A later cold-boot baseline scored 15,570 / 15,263 / 15,260, median **15,263**, only 0.19% above batching. Its graphics median was 34,763 and physics median 5,153. These changing results and overlapping ranges do not support attributing the earlier gap to the Vulkan flag or claiming an OpenGL ES speedup.
- Regular Sling Shot returned **Maxed Out!**, with graphics tests near 60 FPS. Its internal historical best score is not a substitute for a numeric result.
- Forced ANGLE/Metal produced black frames and shader compilation errors. Its internally calculated score is excluded; the configuration is not offered by Mandroid.
- A corrupted Sling Shot asset download caused a native crash. Reinstalling the benchmark assets resolved it before the controlled series.
- A background Play services update killed an exploratory run. Networking and Play Store were disabled in the dedicated AVD before restarting the controlled series; no production guest settings were changed.
- Headless `-gpu auto` selected CPU software renderers (lavapipe/SwiftShader) on this installation. No software score is claimed. Mandroid uses a hidden Qt window, so this probe does not establish what `auto` selects in the app.

These are local emulator measurements on one Mac, not native-device scores or a guarantee across games. The timed series uses `-no-window` and does not include Mandroid's gRPC frame streaming and window presentation overhead. Guest-reported temperature is virtual; `pmset -g therm` reported no thermal or performance warnings, which is not a measurement of a fixed host temperature.

## Selected configuration

Mandroid defaults to **Hardware (Vulkan batching)**: `-gpu host -feature Vulkan,VulkanBatchedDescriptorSetUpdate`. It had the highest median in both Wild Life Unlimited comparison series. The gain was about 1%, and Sling Shot results varied; this is a Vulkan-focused tuning choice, not a promise that every game is faster.

Settings keeps the original **Hardware** profile for compatibility, plus the emulator's automatic and software modes. Changing the profile cold-boots Android while preserving installed apps and user data. Mandroid clears the forced ANGLE/Metal and two experimental MoltenVK environment overrides so they cannot silently replace the selected configuration. Vulkan continues to use the emulator's MoltenVK path to the Apple GPU; the `host` GLES renderer remains the OpenGL ES translator.

Runtime validation used the real Debug Mandroid app with an isolated copy of the benchmark guest, `-qt-hide-window`, batching enabled, and a 2560 × 1600 app display. Host clicks selected and started Wild Life, the gRPC stream showed the animated scene correctly, and the benchmark reached its result screen. This single regular Wild Life smoke run scored **7,106 / 42.55 FPS** while snapshots were captured. It is not part of the uninterrupted Unlimited comparison above and does not establish an app-window speedup. The lower presentation-path result reinforces why the headless scores must not be described as windowed game FPS.
