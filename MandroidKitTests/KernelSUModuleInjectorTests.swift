import Foundation
import Testing
@testable import MandroidKit

/// A guest that records the commands a procedure runs and answers with what
/// the test says, so an install and its cleanup can be watched without a
/// device.
private final class RecordingGuest: GuestCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private let answer: @Sendable (String) throws -> String

    init(answer: @escaping @Sendable (String) throws -> String = { _ in "" }) {
        self.answer = answer
    }

    var ran: [String] { lock.withLock { commands } }

    func shell(_ command: String, timeout: Duration) async throws -> String {
        lock.withLock { commands.append(command) }
        return try answer(command)
    }

    func run(_ args: [String], timeout: Duration) async throws -> String {
        lock.withLock { commands.append(args.joined(separator: " ")) }
        return ""
    }
}

@Suite struct KernelSUModuleInjectorTests {
    private static let staging = "/data/local/tmp/capture-ca-x"
    private static let listing = "-rw-r--r-- 1 root root u:object_r:system_security_cacerts_file:s0 1818 2026-10-16 17:02 /system/etc/security/cacerts/c76e9e25.0"

    private static func certificate() -> CaptureCertificate {
        CaptureCertificate(der: Data([0x30]), pem: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
                           subject: "Capture CA", notBefore: Date(), notAfter: Date(), storeFileName: "c76e9e25.0")
    }

    @Test func installCommandsCopyApplyAndCleanUpInOrder() throws {
        let commands = KernelSUModuleInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging)
        try #require(commands.count == 3)
        let module = GuestTrustStore.moduleDirectory
        #expect(commands[0].contains("cp \(Self.staging)/* \(module)/"))
        #expect(commands[0].contains("chmod 755 \(module)/service.sh"))
        #expect(commands[0].contains("chmod 644 \(module)/module.prop \(module)/c76e9e25.0"))
        #expect(commands[1] == "sh \(module)/service.sh")
        #expect(commands[2] == "rm -r \(Self.staging)")
    }

    @Test func installCommandsCanTargetAnotherModuleDirectory() throws {
        let commands = KernelSUModuleInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging,
                                                             module: "/data/local/tmp/capture-ca-x")
        try #require(commands.count == 3)
        #expect(commands[0].contains("/data/local/tmp/capture-ca-x/c76e9e25.0"))
        #expect(commands[2] == "rm -r \(Self.staging)")
    }

    @Test func installCommandsSurviveTheRootShellWrapper() {
        let commands = KernelSUModuleInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging)
        // Every command runs as `su -c '<command>'` and one per line.
        #expect(commands.allSatisfy { !$0.isEmpty && !$0.contains("'") && !$0.contains("\n") })
    }

    @Test func verifiedInstallLeavesTheModuleInPlace() async throws {
        let guest = RecordingGuest { _ in Self.listing }
        let installation = try await KernelSUModuleInjector().install(Self.certificate(), adb: guest)
        #expect(installation.fileName == "c76e9e25.0")
        #expect(installation.backend == .kernelSUModule)
        #expect(!guest.ran.contains { $0.contains("rm -r \"$MODDIR\"") })
    }

    @Test func failedVerifyRemovesTheModuleItJustInstalled() async throws {
        // The entry never became visible, so the module must not stay behind:
        // it would re-trust the CA at every boot with no record and no way for
        // the user to take it out.
        let guest = RecordingGuest { _ in "" }
        let error = await #expect(throws: MandroidKitError.self) {
            _ = try await KernelSUModuleInjector().install(Self.certificate(), adb: guest)
        }
        #expect(error == .adb("The certificate store entry was not visible after install."))
        #expect(guest.ran.contains { $0.contains("rm -r \"$MODDIR\"") && $0.contains("umount") })
    }

    @Test func entryNotVisibleToAppsAlsoRemovesTheModule() async throws {
        // The shell listing shows the entry while zygote's namespace does not:
        // apps would not trust the CA, and the failure must not leave a live
        // module behind either.
        let guest = RecordingGuest { command in
            command.contains("pidof zygote64") ? "" : Self.listing
        }
        let error = await #expect(throws: MandroidKitError.self) {
            _ = try await KernelSUModuleInjector().install(Self.certificate(), adb: guest)
        }
        #expect(error == .adb("The certificate store entry is present but not visible in an app namespace."))
        #expect(guest.ran.contains { $0.contains("rm -r \"$MODDIR\"") })
    }

    @Test func failedInstallCommandRemovesTheModuleToo() async throws {
        let guest = RecordingGuest { command in
            if command.contains("service.sh") { throw MandroidKitError.adb("service.sh failed (1)") }
            return ""
        }
        let error = await #expect(throws: MandroidKitError.self) {
            _ = try await KernelSUModuleInjector().install(Self.certificate(), adb: guest)
        }
        #expect(error == .adb("service.sh failed (1)"))
        #expect(guest.ran.contains { $0.contains("rm -r \"$MODDIR\"") })
    }

    @Test func removalIsRenderedFromTheRecordItIsGiven() async throws {
        let guest = RecordingGuest()
        let installation = CaptureInstallation(fileName: "c76e9e25.0", subject: "Capture CA", notAfter: Date(),
                                               backend: .kernelSUModule, installedAt: Date())
        try await KernelSUModuleInjector().remove(installation, adb: guest)
        #expect(guest.ran.contains { $0.contains("ENTRY=$MODDIR/c76e9e25.0") })
    }

    @Test func removalRefusesARecordFromAnotherInstaller() async throws {
        let guest = RecordingGuest()
        let installation = CaptureInstallation(fileName: "c76e9e25.0", subject: "Capture CA", notAfter: Date(),
                                               backend: .writableSystem, installedAt: Date())
        let error = await #expect(throws: MandroidKitError.self) {
            try await KernelSUModuleInjector().remove(installation, adb: guest)
        }
        #expect(error == .adb("The recorded certificate was not installed as a KernelSU module."))
        #expect(guest.ran.isEmpty)
    }
}
