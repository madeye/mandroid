import Foundation

/// Command line for one emulator instance.
public struct EmulatorLaunchOptions: Sendable, Hashable {
    public var avdName: String
    public var consolePort: Int        // even, adb serial is emulator-<consolePort>
    public var grpcPort: Int
    public var adbServerPort: Int
    public var coldBoot: Bool = false
    public var gpuBackend: GPUBackend = .defaultBackend
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
        if coldBoot { args += ["-no-snapshot-load"] }
        args += extraArguments
        return args
    }
}
