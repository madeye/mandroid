import Foundation

/// Host graphics paths. Vulkan stays enabled for Android games on every path.
public enum GPUBackend: String, CaseIterable, Sendable {
    case hostBatched
    case host
    case automatic
    case software

    /// Highest median in both Wild Life Unlimited comparison series on M4.
    /// Keep the unbatched host path available for compatibility.
    public static let defaultBackend: GPUBackend = .hostBatched

    public var label: String {
        switch self {
        case .host: "Hardware"
        case .hostBatched: "Hardware (Vulkan batching)"
        case .automatic: "Emulator automatic"
        case .software: "Software"
        }
    }

    public var emulatorMode: String {
        switch self {
        case .host, .hostBatched: "host"
        case .automatic: "auto"
        case .software: "software"
        }
    }

    public var emulatorFeatures: String {
        self == .hostBatched ? "Vulkan,VulkanBatchedDescriptorSetUpdate" : "Vulkan"
    }

    /// Keep the selected profile independent of experimental shell overrides.
    /// Forced ANGLE/Metal can report a Metal device while producing black frames.
    public func environment(from inherited: [String: String]) -> [String: String] {
        var env = inherited
        env.removeValue(forKey: "ANDROID_EGL_ON_EGL")
        env.removeValue(forKey: "ANGLE_DEFAULT_PLATFORM")
        env.removeValue(forKey: "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS")
        env.removeValue(forKey: "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS")
        return env
    }
}
