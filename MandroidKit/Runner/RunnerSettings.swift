import Foundation

/// User-adjustable settings, persisted in `UserDefaults`.
public struct RunnerSettings: Sendable, Equatable {
    /// Nil preserves the guest volume until the user first adjusts it.
    public var mediaVolumePercent: Int?
    public var ramMB: Int = 4096
    public var cores: Int = 4
    public var gpuBackend: GPUBackend = .defaultBackend
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
        if let v = defaults.object(forKey: "mediaVolumePercent") as? Int, (0...100).contains(v) { s.mediaVolumePercent = v }
        if let v = defaults.object(forKey: "ramMB") as? Int, ramChoices.contains(v) { s.ramMB = v }
        if let v = defaults.object(forKey: "cores") as? Int, coreChoices.contains(v) { s.cores = v }
        if let v = defaults.object(forKey: "defaultWindowHeight") as? Int, (500...1600).contains(v) { s.defaultWindowHeight = v }
        if let v = defaults.object(forKey: "launcherStubs") as? Bool { s.launcherStubs = v }
        if let v = defaults.object(forKey: "landscapeByDefault") as? Bool { s.landscapeByDefault = v }
        if let v = defaults.string(forKey: "downloadMirror"), let m = DownloadMirror.Preference(rawValue: v) { s.downloadMirror = m }
        if let value = defaults.string(forKey: "gpuBackend"), let backend = GPUBackend(rawValue: value) { s.gpuBackend = backend }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(mediaVolumePercent, forKey: "mediaVolumePercent")
        defaults.set(ramMB, forKey: "ramMB")
        defaults.set(cores, forKey: "cores")
        defaults.set(gpuBackend.rawValue, forKey: "gpuBackend")
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

    /// Applies the hardware settings to an AVD config.
    public func apply(to config: inout AVDConfig) {
        config.ramMB = ramMB
        config.cores = cores
        config.gpuBackend = gpuBackend
    }
}
