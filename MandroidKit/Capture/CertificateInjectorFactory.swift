import Foundation

/// Picks the injector that matches what the running session can actually do.
/// A shell that is root writes the store directly; a shell that only reaches
/// root through `su` has a KernelSU patch behind it and gets a module; a shell
/// with neither has no path to the store, which is reported as nil so the
/// caller can say why the feature is unavailable rather than letting an
/// injector fail somewhere in the middle of a procedure.
public enum CertificateInjectorFactory {
    public static func injector(for capabilities: GuestSessionCapabilities) -> (any CertificateInjecting)? {
        switch capabilities {
        case .kernelSUShellRoot: KernelSUModuleInjector()
        case .adbRoot: WritableSystemInjector()
        case .none: nil
        }
    }

    /// How one recorded installation is taken back out: the injector that owns
    /// the artifact the record names, or the record this session cannot act on.
    /// The record decides the procedure, not the session shape: the other
    /// injector takes out what it can reach and leaves the artifact that
    /// exists — a KernelSU module whose boot hook puts the certificate back, or
    /// an entry sitting on the writable system image — so a removal that ran
    /// the wrong one would report success while the certificate stayed trusted.
    public static func remover(for backend: CaptureBackend,
                               capabilities: GuestSessionCapabilities) -> CertificateRemovalPlan {
        switch backend {
        case .kernelSUModule:
            // Removing the module runs through `su`, which is what the KernelSU
            // patch provides; a shell that only got root from `adb root` cannot
            // reach it.
            guard capabilities == .kernelSUShellRoot else { return .refused(backend) }
            return .injector(KernelSUModuleInjector())
        case .writableSystem:
            // Removing the entry runs through the daemon's own root shell on
            // the writable system partition.
            guard capabilities == .adbRoot else { return .refused(backend) }
            return .injector(WritableSystemInjector())
        }
    }
}

/// What taking one recorded installation out uses, or why this session cannot
/// do it.
public enum CertificateRemovalPlan: Sendable {
    /// The injector that owns the artifact the record names, which this
    /// session can run.
    case injector(any CertificateInjecting)
    /// The session's shell cannot run the procedure this backend needs; the
    /// backend is carried so the caller can name the session that can.
    case refused(CaptureBackend)
}
