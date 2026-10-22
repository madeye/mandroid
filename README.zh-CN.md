<p align="center">
  <img src="Mandroid/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="Mandroid app icon">
</p>

# Mandroid

[English](README.md) | 简体中文

在 Mac 上像运行原生 macOS 应用一样运行 Android 应用。每个 Android 应用都有自己的窗口，带正常的标题栏，可以像 Mac 窗口一样缩放，与系统剪贴板互通，响应 Cmd 快捷键，并出现在 Dock 和 Spotlight 中 —— 没有手机外框，也没有 Android 状态栏和导航栏。

**状态：可用的原型。** 阶段 0–3 的核心工作流已经实现并端到端验证过（首次下载、启动、带触摸的 App 窗口、键盘、滚动、自由缩放、剪贴板、启动器存根）。签名并公证过的构建在 [Releases](https://github.com/madeye/mandroid/releases) 页面；也可以从源码构建。设计与分阶段计划在 [`docs/`](docs/) 下：

- [docs/DESIGN.md](docs/DESIGN.md) — 架构、已验证的事实、机制、风险
- [docs/PLAN.md](docs/PLAN.md) — 各阶段及其“完成标准”和状态
- [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md) — 支撑设计决策的测量数据
- [docs/compat.md](docs/compat.md) — 逐应用兼容性与显示配置测试
- [docs/KERNELSU.md](docs/KERNELSU.md) — 可选的 root 支持、支持的镜像与恢复方式

## 构建

```bash
brew install xcodegen protobuf   # 仅在需要重新生成 gRPC 代码时安装 protobuf
xcodegen generate
xcodebuild -scheme Mandroid -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Mandroid-*/Build/Products/Debug/Mandroid.app
```

首次启动时，应用会列出将要下载的内容（约 2.5 GB，来自 `dl.google.com`），并把所有内容安装到 `~/Library/Application Support/Mandroid/` 下。系统区域设置为中国大陆的 Mac 会改用腾讯云镜像（aapt2 走阿里云）；可以在设置界面或 Settings ▸ Downloads 中更改。

## 工作原理

首次启动时，应用会下载官方 Android Emulator、platform-tools 和一个 Google Play 系统镜像，并以后台（无窗口）方式启动模拟器。每打开一个 Android 应用，它会在模拟器内创建一个私有虚拟显示，把应用启动到该显示上，再通过模拟器的 gRPC API 把该显示的像素流式传进一个 macOS 窗口。内置设备使用 Pixel Tablet 尺寸的 2560×1600、320 dpi 显示；应用窗口按自身的物理像素尺寸渲染，并在缩放时重新配置 Android。新窗口默认 1280×800 点（2× Retina 屏上为 2560×1600 像素），在较小屏幕上会等比缩小。鼠标、键盘、滚动与剪贴板以同样的方式反向翻译。

## 设置

Settings（⌘,）里有一个作用于所有 Android 应用的媒体音量滑块。它控制 guest 的原生媒体流，支持静音，并在重启后恢复你设定的音量。音频继续通过模拟器原生的 macOS 后端播放。

用于布局兼容性测试时，Settings ▸ Virtual device ▸ Device screen profile 提供 Tablet（1280×800 dp）、Phone（400×900 dp）、Compact phone（360×640 dp）和 Custom。预设使用 320 dpi；Custom 支持 320–1600 dp 的宽高与 120–480 dpi 的密度。Restart Emulator 会以冷启动应用显示更改，并保留已安装的应用与数据。打开 Device Screen 并在其中启动 Android 应用即可测试所选配置。独立的 App 窗口仍然遵循各自的窗口尺寸。这些配置只影响显示几何；Android 设备标识与认证仍沿用官方模拟器镜像。

Settings ▸ KernelSU（实验性）可以准备一个单独的已打补丁 ramdisk 并以 root 启动。默认关闭。打开 **Boot with KernelSU**，然后 **Restart to Apply**。首次带 root 启动会下载并校验 KernelSU 3.3.0，如有需要会安装其 Manager。你也可以用 **Prepare Patched Image** 提前准备镜像。支持的镜像是 Android 36.1 ARM64 revision 4，内核为 `6.12.38-android16-5-gbb9513914902-ab13996879-4k`；其他内核会被拒绝。带 root 的会话会冷启动。关闭 KernelSU 并重启即可回到 stock，同时保留已安装的应用与数据。root 授权在 KernelSU Manager 中管理；仅开启 KernelSU 不会给 ADB shell root；抓包证书功能才会准备带 shell root 的 ramdisk。见 [KernelSU settings](docs/KERNELSU.md)。

Settings ▸ Camera & Microphone 让 Android 应用可以使用这台 Mac 的摄像头（作为前置摄像头）和麦克风，用于语音和视频通话。两者默认关闭；应用首次录音时 macOS 会请求权限。更改后请重启 Android。

Settings ▸ Virtual device 默认使用硬件图形（Vulkan descriptor batching），也可以选择原来的 hardware、automatic 与 software 配置。更改后端后请重启 Android；现有应用数据会保留。测量协议与各后端结果见 [GPU benchmarks](docs/GPU-BENCHMARKS.md)。

## 环境要求

- Apple 芯片（M1 或更新）的 Mac，运行 macOS 15 或更新。不支持 Intel Mac；应用只构建 arm64。
- 约 2.5 GB 磁盘用于模拟器和系统镜像（首次启动时下载），外加 Android 应用与数据所需空间
- 无需安装 Java、Android Studio 或 SDK

## 限制

- 每个模拟器实例最多同时打开三个 Android 应用窗口（模拟器限制）；更多窗口会被挂起，点击后恢复
- 需要 Play Integrity 认证的应用（许多银行与 DRM 应用）不受支持；开启 KernelSU 也不会得到通过的判定

## 路线图

实现状态与剩余工作见 [docs/PLAN.md](docs/PLAN.md)。后续候选包括 Android 侧的显示提供方（以解除三窗口限制）、第二个模拟器实例，以及 macOS 通知桥接。

## 离屏 UI 测试

构建 Debug 版后，用 APK 运行真实模拟器冒烟测试：

```sh
python3 Scripts/run-ui-tests.py --app /path/to/Mandroid.app --apk /path/to/app.apk --package com.example.app
```

只测音量控制时，用 `--test volume` 代替 `--apk` 与 `--package`。这会通过与 Settings 相同的原生 Android 控制路径检查静音、满音量与中间音量，然后恢复之前的音量。

启动器在 `~/Library/Caches/mandroid-ui-*` 下使用全新的 guest 数据，复用 Mandroid 已安装的 SDK 与工具，并在结束后关闭自己的进程。窗口保持隐藏；输入与缩放命令走一个私有文件队列。测试会检查渲染帧、guest 分辨率、显示清理以及没有可见窗口。截图与日志保留在打印出的产物目录中。帧检查需要 Python Pillow。仅 Debug 可用的模式会禁用剪贴板共享与启动器创建，不影响正常的应用会话。

## 本地审计流程

运行 `Scripts/audit.sh` 会构建 Debug 与 Release、运行单元测试、检查脚本语法，并校验生成的 protobuf 源码。加上 `--apk /path/to/app.apk --package com.example.app` 可做隔离的真实模拟器检查，包括重复启动，以及在显示被复用后关闭被挂起的窗口。发现与范围见 [the audit report](docs/AUDIT.md)。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。

## 从 Madroid 升级

打开 Mandroid 前先退出 Madroid。首次启动时，Mandroid 会把现有的 SDK、Android 虚拟设备、已安装应用与图标缓存从 `~/Library/Application Support/Madroid` 移到 `~/Library/Application Support/Mandroid`，并复制你的偏好设置。Android App Runner 的安装也受支持。已有的 Mandroid 数据永远不会被覆盖。旧的 `madroid://` 链接仍然可用，已生成的应用启动器会更新为使用 `mandroid://`。

## 逐应用 HTTP 代理

在应用库中右键某个应用，选择 **HTTP Proxy…**。启用代理，填入主机与端口并保存。每个应用可以同时使用不同的代理。代理运行在这台 Mac 上时用 `localhost`。配置在重启后保留；关掉其中一个应用的代理不会影响其他应用。

这会配置 Android 的 HTTP 代理推荐（包括 HTTPS CONNECT）。忽略 Android HTTP 代理设置的应用仍然直连。该助手使用 Android 的 VPN 连接，会替换其他已启用的 Android VPN。不会安装任何 TLS 证书，加密流量不会被解密。

## 抓包证书

Settings ▸ Capture certificates 会把调试代理的根 CA 装进虚拟设备的系统信任库，让应用信任代理抓到的 HTTPS 流量。你可以选择代理的证书文件、粘贴其 PEM，或填入代理的主机与端口从它那里获取 CA；Mandroid 会在安装前显示主题与有效期，并且在配置了代理时会先检查代理确实用所选 CA 签名。安装需要 rooted 会话，有两种形态。使用 KernelSU 时，打开 **Boot with KernelSU** 与抓包证书开关再重启：这两者一起才会准备 shell-root ramdisk。另一种是启用 **Boot with a writable system partition** 启动 `google_apis` 镜像，其证书库会在模拟器每次启动时由 Mandroid 重建。Chrome 用自己的根证书库校验，会忽略已安装的 CA；做了证书固定的应用仍然会失败。见 [Certificate injection](docs/CERTIFICATE-INJECTION.md)。
