import Foundation

/// What root the shell of one running session can actually reach. The answer
/// comes from the guest, not from a build property, so it stays true when an
/// image's root story changes.
public enum GuestSessionCapabilities: Sendable, Equatable {
    /// The shell itself is root: a `userdebug` image that accepted `adb root`.
    case adbRoot
    /// Only `su` reaches root: the KernelSU patch granted the shell access.
    case kernelSUShellRoot
    case none

    public static func classify(idOutput: String, suOutput: String?) -> GuestSessionCapabilities {
        if idOutput.contains("uid=0(") { return .adbRoot }
        if let suOutput, suOutput.contains("uid=0(") { return .kernelSUShellRoot }
        return .none
    }

    /// Probes a booted guest: `id` shows what the shell is, `su -c id` what
    /// root escalation offers.
    public static func detect(adb: ADBClient) async -> GuestSessionCapabilities {
        let idOutput = (try? await adb.shell("id")) ?? ""
        let suOutput = try? await adb.shell("su -c id")
        return classify(idOutput: idOutput, suOutput: suOutput)
    }
}

extension GuestSessionCapabilities {
    /// Whether a recorded installation has to be put back into effect at the
    /// start of this session. A KernelSU module re-applies itself from its boot
    /// hook; a writable-system entry survives on the AVD's system partition but
    /// its runtime bind does not, so the store has to be rebuilt on every boot,
    /// which only a shell that is root can do.
    public func shouldReapply(_ installation: CaptureInstallation?) -> Bool {
        installation?.backend == .writableSystem && self == .adbRoot
    }
}
