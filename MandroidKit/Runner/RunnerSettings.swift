import Foundation

/// User-adjustable settings, persisted in `UserDefaults`.
public struct RunnerSettings: Sendable, Equatable {
    /// Nil preserves the guest volume until the user first adjusts it.
    public var mediaVolumePercent: Int?
    public var kernelSUEnabled = false
    /// Install a capture proxy's CA into the guest trust store. Enabling this
    /// implies shell root on the patched ramdisk, which is why it is separate
    /// from `kernelSUEnabled`.
    public var captureCertificateEnabled = false
    /// Boot the guest with a writable system partition, which a `userdebug`
    /// image needs before the capture certificate can go into the system store
    /// as root. Independent of `captureCertificateEnabled`: one chooses the
    /// image's partition, the other what is put on it.
    public var writableSystemEnabled = false
    /// Which installed system image the emulator boots, by tag. Independent of
    /// `writableSystemEnabled`: choosing both is what a writable system session
    /// needs, but neither turns the other on.
    public var systemImageTag: String = SDKBootstrap.defaultTag
    public var ramMB: Int = 4096
    public var cores: Int = 4
    public var gpuBackend: GPUBackend = .defaultBackend
    public var deviceProfile: DeviceProfile = .tablet
    public var customDeviceWidthDP: Int = 400
    public var customDeviceHeightDP: Int = 900
    public var customDeviceDensity: Int = 320
    /// Expose this Mac's microphone to Android apps (`-allow-host-audio`).
    /// Off by default so a fresh install never triggers a macOS privacy prompt.
    public var hostMicrophone: Bool = false
    /// Use this Mac's camera as the Android front camera (`hw.camera.front=webcam0`).
    public var hostCamera: Bool = false
    public var defaultWindowHeight: Int = 800
    public var launcherStubs: Bool = true
    /// New app windows open in landscape ("horizontal") unless changed.
    public var landscapeByDefault: Bool = true
    /// Which download host to prefer for SDK components and aapt2.
    public var downloadMirror: DownloadMirror.Preference = .auto

    public static let ramChoices = [2048, 3072, 4096, 6144, 8192]
    public static let coreChoices = [2, 4, 6, 8]

    public init() {}

    public static func load(from defaults: UserDefaults = .standard) -> RunnerSettings {
        var s = RunnerSettings()
        s.kernelSUEnabled = defaults.bool(forKey: "kernelSUEnabled")
        s.captureCertificateEnabled = defaults.bool(forKey: "captureCertificateEnabled")
        s.writableSystemEnabled = defaults.bool(forKey: "writableSystemEnabled")
        if let tag = defaults.string(forKey: "systemImageTag"), !tag.isEmpty { s.systemImageTag = tag }
        if let v = defaults.object(forKey: "mediaVolumePercent") as? Int, (0...100).contains(v) { s.mediaVolumePercent = v }
        if let v = defaults.object(forKey: "ramMB") as? Int, ramChoices.contains(v) { s.ramMB = v }
        if let v = defaults.object(forKey: "cores") as? Int, coreChoices.contains(v) { s.cores = v }
        // bool(forKey:) also accepts "YES"/"NO" strings from `-hostCamera YES` launch arguments.
        if defaults.object(forKey: "hostMicrophone") != nil { s.hostMicrophone = defaults.bool(forKey: "hostMicrophone") }
        if defaults.object(forKey: "hostCamera") != nil { s.hostCamera = defaults.bool(forKey: "hostCamera") }
        if let v = defaults.object(forKey: "defaultWindowHeight") as? Int, (500...1600).contains(v) { s.defaultWindowHeight = v }
        if let v = defaults.object(forKey: "launcherStubs") as? Bool { s.launcherStubs = v }
        if let v = defaults.object(forKey: "landscapeByDefault") as? Bool { s.landscapeByDefault = v }
        if let v = defaults.string(forKey: "downloadMirror"), let m = DownloadMirror.Preference(rawValue: v) { s.downloadMirror = m }
        if let value = defaults.string(forKey: "gpuBackend"), let backend = GPUBackend(rawValue: value) { s.gpuBackend = backend }
        if let value = defaults.string(forKey: "deviceProfile"), let profile = DeviceProfile(rawValue: value) { s.deviceProfile = profile }
        // integer(forKey:) also accepts numeric launch arguments for isolated tests.
        let width = defaults.integer(forKey: "customDeviceWidthDP")
        let height = defaults.integer(forKey: "customDeviceHeightDP")
        let density = defaults.integer(forKey: "customDeviceDensity")
        if DeviceDisplay.dimensionRange.contains(width) { s.customDeviceWidthDP = width }
        if DeviceDisplay.dimensionRange.contains(height) { s.customDeviceHeightDP = height }
        if DeviceDisplay.densityRange.contains(density) { s.customDeviceDensity = density }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(mediaVolumePercent, forKey: "mediaVolumePercent")
        defaults.set(kernelSUEnabled, forKey: "kernelSUEnabled")
        defaults.set(captureCertificateEnabled, forKey: "captureCertificateEnabled")
        defaults.set(writableSystemEnabled, forKey: "writableSystemEnabled")
        defaults.set(systemImageTag, forKey: "systemImageTag")
        defaults.set(ramMB, forKey: "ramMB")
        defaults.set(cores, forKey: "cores")
        defaults.set(gpuBackend.rawValue, forKey: "gpuBackend")
        defaults.set(deviceProfile.rawValue, forKey: "deviceProfile")
        defaults.set(customDeviceWidthDP, forKey: "customDeviceWidthDP")
        defaults.set(customDeviceHeightDP, forKey: "customDeviceHeightDP")
        defaults.set(customDeviceDensity, forKey: "customDeviceDensity")
        defaults.set(hostMicrophone, forKey: "hostMicrophone")
        defaults.set(hostCamera, forKey: "hostCamera")
        defaults.set(defaultWindowHeight, forKey: "defaultWindowHeight")
        defaults.set(launcherStubs, forKey: "launcherStubs")
        defaults.set(landscapeByDefault, forKey: "landscapeByDefault")
        defaults.set(downloadMirror.rawValue, forKey: "downloadMirror")
    }

    /// Default logical size of a new app window given the usable screen size.
    /// Landscape: 16:10 with the height derived from `defaultWindowHeight`;
    /// portrait: a 420:900 phone rectangle.
    public func defaultWindowSize(screenWidth: Double, screenHeight: Double) -> (width: Double, height: Double) {
        let maxH = max(400, screenHeight - 40), maxW = max(400, screenWidth - 40)
        if landscapeByDefault {
            var h = min(Double(defaultWindowHeight), maxH)
            var w = (h * 1.6).rounded()
            if w > maxW { w = maxW; h = (w / 1.6).rounded() }
            return (w, h)
        } else {
            let h = min(Double(defaultWindowHeight), maxH)
            return ((h * 420 / 900).rounded(), h)
        }
    }

    /// Mirrors to try, in order, for the current preference.
    public var mirrors: [DownloadMirror] { DownloadMirror.order(for: downloadMirror) }

    public var deviceDisplay: DeviceDisplay {
        deviceProfile.display(widthDP: customDeviceWidthDP, heightDP: customDeviceHeightDP, density: customDeviceDensity)
    }

    public func requiresRestart(comparedTo running: RunnerSettings) -> Bool {
        ramMB != running.ramMB || cores != running.cores || gpuBackend != running.gpuBackend
            || deviceDisplay != running.deviceDisplay || kernelSUEnabled != running.kernelSUEnabled
            || hostMicrophone != running.hostMicrophone || hostCamera != running.hostCamera
            || writableSystemEnabled != running.writableSystemEnabled
            || systemImageTag != running.systemImageTag
    }

    /// Applies the hardware settings to an AVD config. The host camera only
    /// replaces the front camera: that is the one calling apps open first, and
    /// the back camera keeps the virtual scene for apps that need one.
    public func apply(to config: inout AVDConfig) {
        config.kernelSUEnabled = kernelSUEnabled
        config.ramMB = ramMB
        config.cores = cores
        config.gpuBackend = gpuBackend
        config.displayName = "Mandroid (\(deviceProfile.label))"
        config.lcdWidth = deviceDisplay.widthPixels
        config.lcdHeight = deviceDisplay.heightPixels
        config.lcdDensity = deviceDisplay.density
        config.frontCamera = hostCamera ? AVDConfig.hostCamera : AVDConfig.fakeFrontCamera
        config.backCamera = AVDConfig.fakeBackCamera
    }

    /// Applies the settings that are command-line flags rather than AVD keys.
    public func apply(to options: inout EmulatorLaunchOptions) {
        options.gpuBackend = gpuBackend
        options.hostAudioInput = hostMicrophone
        options.writableSystem = writableSystemEnabled
    }
}
