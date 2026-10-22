import Foundation
import Testing
@testable import MandroidKit

/// The controller keeps the injector it was given, so the install tally has to
/// live in a reference the test's copy shares with the controller's.
private final class FakeInjector: CertificateInjecting, @unchecked Sendable {
    var installError: Error?
    private let lock = NSLock()
    private var installs = 0
    private var removals: [CaptureInstallation] = []
    private var storage: [CaptureInstallation] = []

    var installCount: Int { lock.withLock { installs } }

    var removed: [CaptureInstallation] { lock.withLock { removals } }

    var recorded: [CaptureInstallation] { lock.withLock { storage } }

    func install(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        lock.withLock { installs += 1 }
        if let installError { throw installError }
        let installation = CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                               notAfter: certificate.notAfter, backend: .kernelSUModule,
                                               installedAt: Date())
        lock.withLock { storage.append(installation) }
        return installation
    }

    func verify(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws -> VerificationState {
        .present(label: "u:object_r:system_security_cacerts_file:s0")
    }

    func remove(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws {
        lock.withLock { removals.append(installation) }
    }
}

@Suite struct CaptureCertificateControllerTests {
    /// A client over a temporary `SDKPaths` with no server behind it. Nothing
    /// here reaches a device: the abort test stops at the verdict, and the
    /// success test stops at the fake injector.
    static func unusedADB() -> ADBClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ADBClient(paths: SDKPaths(root: root), serverPort: 5137, serial: "emulator-5554")
    }

    @Test func installWritesRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureCertificateStore(root: root)
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: store, injector: injector,
                                                      verdict: { _ in .trusted })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(try store.load() == nil)

        let installation = try await controller.install(certificate, adb: Self.unusedADB())

        let recorded = try store.load()
        #expect(injector.installCount == 1)
        #expect(recorded?.fileName == certificate.storeFileName)
        #expect(recorded == installation)
        let state = await controller.state
        #expect(state == .installed(installation))
    }

    @Test func unverifiedInstallWritesRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureCertificateStore(root: root)
        let injector = FakeInjector()
        // The verdict would refuse, so only an install that skips the provider
        // can reach the injector.
        let controller = CaptureCertificateController(store: store, injector: injector,
                                                     verdict: { _ in .foreignIssuer("Other CA") })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(try store.load() == nil)

        let installation = try await controller.installUnverified(certificate, adb: Self.unusedADB())

        let recorded = try store.load()
        #expect(injector.installCount == 1)
        #expect(recorded == installation)
        let state = await controller.state
        #expect(state == .installed(installation))
    }

    @Test func removalClearsRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureCertificateStore(root: root)
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        try store.save(CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                           notAfter: certificate.notAfter, backend: .writableSystem, installedAt: Date()))
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func foreignIssuerStopsBeforeInstalling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = ChainVerdict.foreignIssuer("Other CA")
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: CaptureCertificateStore(root: root),
                                                     injector: injector,
                                                     verdict: { _ in verdict })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        let error = await #expect(throws: CapturePreflightError.self) {
            _ = try await controller.install(certificate, adb: Self.unusedADB())
        }
        // The verdict travels inside the error, not flattened into a message.
        #expect(error == .verdict(verdict))
        #expect(injector.installCount == 0)
    }

    @Test func aRecordWriteThatCannotLandTakesTheInstallBackOut() async throws {
        // The injector has left the certificate live when the record is
        // written; a record that cannot land must not leave the guest and the
        // record disagreeing. The root is a file, so the store writes nothing
        // while still reading as empty.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        let store = CaptureCertificateStore(root: root)
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: store, injector: injector,
                                                      verdict: { _ in .trusted })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(try store.load() == nil)

        await #expect(throws: (any Error).self) {
            _ = try await controller.install(certificate, adb: Self.unusedADB())
        }

        #expect(injector.installCount == 1)
        #expect(injector.removed.map(\.fileName) == [certificate.storeFileName])
        let state = await controller.state
        #expect(state == .idle)
    }

    @Test func aGenuineFirstInstallFailureStillCleansUp() async throws {
        // Nothing was recorded before this install, so the cleanup path may
        // run and must: the guest would otherwise hold a certificate nothing
        // accounts for.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        let store = CaptureCertificateStore(root: root)
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: store, injector: injector,
                                                      verdict: { _ in .trusted })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))

        await #expect(throws: (any Error).self) {
            _ = try await controller.installUnverified(certificate, adb: Self.unusedADB())
        }

        #expect(injector.removed.count == 1)
    }

    @Test func secondInstallIsRefusedWhileARecordExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureCertificateStore(root: root)
        let existing = CaptureInstallation(fileName: "other0000.0", subject: "Already There", notAfter: Date(),
                                           backend: .kernelSUModule, installedAt: Date())
        try store.save(existing)
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: store, injector: injector,
                                                      verdict: { _ in .trusted })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))

        let error = await #expect(throws: CaptureInstallError.self) {
            _ = try await controller.install(certificate, adb: Self.unusedADB())
        }

        // A second install would strand the recorded certificate behind an
        // unconditional cleanup, so it never reaches the injector.
        #expect(error == .alreadyInstalled(existing))
        #expect(error?.localizedDescription.contains("Remove it first") == true)
        #expect(injector.installCount == 0)
        #expect(injector.removed.isEmpty)
    }

    @Test func notInterceptedWordingIsHonestAboutTheAmbiguity() {
        // The check only knows the chain is one this Mac already trusts: the
        // copy must not claim to know the proxy is idle.
        let message = CapturePreflightError.verdict(.notIntercepted).localizedDescription
        #expect(message.contains("already trusts"))
        #expect(message.contains("not intercepting"))
        #expect(message.contains("different CA"))
    }

    @Test func foreignIssuerWordingNamesTheIssuer() {
        let message = CapturePreflightError.verdict(.foreignIssuer("Other CA")).localizedDescription
        #expect(message.contains("Other CA"))
        #expect(message.contains("not with the certificate you chose"))
    }
}
