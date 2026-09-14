import Foundation

/// Hardware profile rendered to `<name>.avd/config.ini`. Values mirror the
/// template in DESIGN §3.4; everything is explicit so no device XML is needed.
public struct AVDConfig: Sendable, Hashable {
    public var name: String = "runner"
    public var displayName: String = "Mandroid (Pixel Tablet)"
    public var systemImagePath: String            // "system-images;android-36.1;google_apis_playstore;arm64-v8a"
    public var ramMB: Int = 4096
    public var cores: Int = 4
    public var heapMB: Int = 512
    public var dataPartitionMB: Int = 16384
    // Pixel Tablet resolution, with xhdpi logical density (1280×800 dp).
    // Natural orientation is landscape because width exceeds height.
    public var lcdWidth: Int = 2560
    public var lcdHeight: Int = 1600
    public var lcdDensity: Int = 320
    public var sdcardSizeMB: Int = 512
    public var gpuMode: String { gpuBackend.emulatorMode }
    public var gpuBackend: GPUBackend = .defaultBackend

    public init(systemImagePath: String) {
        self.systemImagePath = systemImagePath
    }

    var parts: [String] { systemImagePath.split(separator: ";").map(String.init) }
    public var target: String { parts.count > 1 ? parts[1] : "android" }
    public var tagID: String { parts.count > 2 ? parts[2] : "default" }
    public var abi: String { parts.count > 3 ? parts[3] : "arm64-v8a" }
    public var cpuArch: String { abi.hasPrefix("arm") ? "arm64" : "x86_64" }
    public var playStoreEnabled: Bool { tagID == "google_apis_playstore" }
    /// `image.sysdir.1` is relative to the SDK root and must end with "/".
    public var imageSysdir: String { parts.joined(separator: "/") + "/" }

    public func renderConfigINI() -> String {
        let entries: [(String, String)] = [
            ("AvdId", name),
            ("PlayStore.enabled", playStoreEnabled ? "true" : "false"),
            ("abi.type", abi),
            ("avd.ini.displayname", displayName),
            ("avd.ini.encoding", "UTF-8"),
            ("disk.dataPartition.size", "\(dataPartitionMB)M"),
            ("fastboot.chosenSnapshotFile", ""),
            ("fastboot.forceChosenSnapshotBoot", "no"),
            ("fastboot.forceColdBoot", "no"),
            ("fastboot.forceFastBoot", "yes"),
            ("hw.accelerometer", "yes"),
            ("hw.arc", "false"),
            ("hw.audioInput", "yes"),
            ("hw.battery", "yes"),
            ("hw.camera.back", "virtualscene"),
            ("hw.camera.front", "emulated"),
            ("hw.cpu.arch", cpuArch),
            ("hw.cpu.ncore", "\(cores)"),
            ("hw.dPad", "no"),
            ("hw.device.manufacturer", "Google"),
            ("hw.gps", "yes"),
            ("hw.gpu.enabled", "yes"),
            ("hw.gpu.mode", gpuMode),
            ("mandroid.gpu.backend", gpuBackend.rawValue),
            ("hw.gyroscope", "yes"),
            ("hw.initialOrientation", "portrait"),
            ("hw.keyboard", "yes"),
            ("hw.lcd.density", "\(lcdDensity)"),
            ("hw.lcd.height", "\(lcdHeight)"),
            ("hw.lcd.width", "\(lcdWidth)"),
            ("hw.mainKeys", "no"),
            ("hw.ramSize", "\(ramMB)"),
            ("hw.sdCard", "yes"),
            ("hw.sensors.light", "yes"),
            ("hw.sensors.magnetic_field", "yes"),
            ("hw.sensors.orientation", "yes"),
            ("hw.sensors.pressure", "yes"),
            ("hw.sensors.proximity", "yes"),
            ("hw.trackBall", "no"),
            ("image.sysdir.1", imageSysdir),
            ("runtime.network.latency", "none"),
            ("runtime.network.speed", "full"),
            ("sdcard.size", "\(sdcardSizeMB)M"),
            ("showDeviceFrame", "no"),
            ("skin.dynamic", "yes"),
            ("skin.name", "\(lcdWidth)x\(lcdHeight)"),
            ("skin.path", "_no_skin"),
            ("tag.display", playStoreEnabled ? "Google Play" : "Google APIs"),
            ("tag.id", tagID),
            ("target", target),
            ("vm.heapSize", "\(heapMB)"),
        ]
        return entries.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    /// `<avdhome>/<name>.ini`
    public func renderPointerINI(avdDirectory: URL) -> String {
        """
        avd.ini.encoding=UTF-8
        path=\(avdDirectory.path)
        path.rel=avd/\(name).avd
        target=\(target)

        """
    }
}
