import Testing
@testable import MandroidKit

@Suite struct CertificateInjectorFactoryTests {
    @Test func kernelSUSessionUsesTheModuleInjector() {
        #expect(CertificateInjectorFactory.injector(for: .kernelSUShellRoot) is KernelSUModuleInjector)
    }

    @Test func writableSystemSessionUsesTheDirectInjector() {
        #expect(CertificateInjectorFactory.injector(for: .adbRoot) is WritableSystemInjector)
    }

    @Test func unprivilegedSessionHasNoInjector() {
        #expect(CertificateInjectorFactory.injector(for: .none) == nil)
    }

    @Test func aModuleRecordIsTakenOutThroughTheModuleInjector() {
        #expect(chosen(remover(for: .kernelSUModule, capabilities: .kernelSUShellRoot)) is KernelSUModuleInjector)
    }

    @Test func aWritableRecordIsTakenOutThroughTheDirectInjector() {
        #expect(chosen(remover(for: .writableSystem, capabilities: .adbRoot)) is WritableSystemInjector)
    }

    /// The other shape's injector takes out what it can reach and leaves the
    /// artifact the record actually names — a module whose boot hook puts the
    /// certificate back, or an entry sitting on the writable system image —
    /// which is a removal that reports success without removing anything.
    @Test func theRecordDecidesTheProcedureNotTheSession() {
        #expect(chosen(remover(for: .kernelSUModule, capabilities: .adbRoot)) == nil)
        #expect(chosen(remover(for: .writableSystem, capabilities: .kernelSUShellRoot)) == nil)
        #expect(refusal(remover(for: .kernelSUModule, capabilities: .adbRoot)) == .kernelSUModule)
        #expect(refusal(remover(for: .writableSystem, capabilities: .kernelSUShellRoot)) == .writableSystem)
    }

    @Test func aSessionWithNoRootTakesNeitherRecordOut() {
        #expect(chosen(remover(for: .kernelSUModule, capabilities: .none)) == nil)
        #expect(chosen(remover(for: .writableSystem, capabilities: .none)) == nil)
        #expect(refusal(remover(for: .kernelSUModule, capabilities: .none)) == .kernelSUModule)
        #expect(refusal(remover(for: .writableSystem, capabilities: .none)) == .writableSystem)
    }

    private func remover(for backend: CaptureBackend,
                         capabilities: GuestSessionCapabilities) -> CertificateRemovalPlan {
        CertificateInjectorFactory.remover(for: backend, capabilities: capabilities)
    }

    /// The injector a plan chose, or nil when it refused.
    private func chosen(_ plan: CertificateRemovalPlan) -> (any CertificateInjecting)? {
        if case .injector(let injector) = plan { return injector }
        return nil
    }

    /// The backend a plan refused, or nil when it chose an injector.
    private func refusal(_ plan: CertificateRemovalPlan) -> CaptureBackend? {
        if case .refused(let backend) = plan { return backend }
        return nil
    }
}
