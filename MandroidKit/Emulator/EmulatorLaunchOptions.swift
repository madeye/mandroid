import Foundation

/// Command line for one emulator instance.
public struct EmulatorLaunchOptions: Sendable, Hashable {
    public var avdName: String
    public var consolePort: Int        // even, adb serial is emulator-<consolePort>
    public var grpcPort: Int
    public var adbServerPort: Int
    public var kernelSURamdisk: URL?
    public var coldBoot: Bool = false
    public var gpuBackend: GPUBackend = .defaultBackend
    /// Pass real microphone samples to the guest. Without `-allow-host-audio`
    /// the emulator zero-fills `hw.audioInput` so apps record silence.
    public var hostAudioInput: Bool = false
    /// Boot with a writable system partition. The guest keeps the changes in a
    /// `system-qemu.img` beside the AVD, and `adb remount` from a root shell can
    /// write the system trust store. Only a `userdebug` image (e.g.
    /// `google_apis`) accepts it; a Play image ignores it.
    public var writableSystem: Bool = false
    public var extraArguments: [String] = []

    public init(avdName: String, consolePort: Int, grpcPort: Int, adbServerPort: Int) {
        self.avdName = avdName
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.adbServerPort = adbServerPort
    }

    public var serial: String { "emulator-\(consolePort)" }

    public var arguments: [String] {
        var args = [
            "-avd", avdName,
            "-port", String(consolePort),
            "-grpc", String(grpcPort),
            "-qt-hide-window",
            "-no-boot-anim",
            "-no-metrics",
            "-gpu", gpuBackend.emulatorMode,
            "-feature", gpuBackend.emulatorFeatures,
        ]
        if writableSystem { args += ["-writable-system"] }
        if let kernelSURamdisk {
            args += ["-ramdisk", kernelSURamdisk.path, "-no-snapshot"]
        } else if coldBoot { args += ["-no-snapshot-load"] }
        if hostAudioInput { args += ["-allow-host-audio"] }
        args += extraArguments
        return args
    }
}
