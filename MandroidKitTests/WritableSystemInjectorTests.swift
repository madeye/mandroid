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

@Suite struct WritableSystemInjectorTests {
    private static let staging = "/data/local/tmp/capture-ca-x"
    private static let listing = "-rw-r--r-- 1 root root u:object_r:system_security_cacerts_file:s0 1818 2026-10-16 17:02 /system/etc/security/cacerts/c76e9e25.0"

    private static func certificate() -> CaptureCertificate {
        CaptureCertificate(der: Data([0x30]), pem: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
                           subject: "Capture CA", notBefore: Date(), notAfter: Date(), storeFileName: "c76e9e25.0")
    }

    @Test func writableSystemInstallCommandsTargetTheSystemStore() {
        let commands = WritableSystemInjector.installCommands(fileName: "c76e9e25.0",
                                                              staging: Self.staging,
                                                              module: Self.staging)
        #expect(commands.contains { $0.contains("remount") })
        #expect(commands.contains { $0.contains("/system/etc/security/cacerts/c76e9e25.0") })
        #expect(commands.contains { $0.contains("chcon") })
        #expect(commands.contains { $0.contains("sh /data/local/tmp/capture-ca-x/service.sh") })
    }

    @Test func installCommandsStageWriteLabelAndApplyInOrder() throws {
        let module = WritableSystemInjector.scriptDirectory
        let commands = WritableSystemInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging)
        try #require(commands.count == 7)
        #expect(commands[0] == "remount")
        #expect(commands[1].contains("cp \(Self.staging)/* \(module)/"))
        #expect(commands[1].contains("chmod 755 \(module)/service.sh"))
        #expect(commands[2] == "cp \(module)/c76e9e25.0 /system/etc/security/cacerts/c76e9e25.0")
        #expect(commands[3].contains("chown root:root /system/etc/security/cacerts/c76e9e25.0"))
        #expect(commands[3].contains("chmod 644 /system/etc/security/cacerts/c76e9e25.0"))
        #expect(commands[4].contains("chcon"))
        #expect(commands[4].contains("/system/etc/security/cacerts/c76e9e25.0"))
        #expect(commands[5] == "sh \(module)/service.sh")
        #expect(commands[6] == "rm -r \(Self.staging)")
    }

    @Test func installCommandsCanTargetAnotherScriptDirectory() throws {
        let commands = WritableSystemInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging,
                                                              module: Self.staging)
        try #require(commands.count == 7)
        #expect(commands[1].contains("/data/local/tmp/capture-ca-x/c76e9e25.0"))
        #expect(commands[5] == "sh \(Self.staging)/service.sh")
    }

    @Test func removeCommandsTakeTheBindsOutOfEveryNamespaceAndDeleteTheEntry() throws {
        let commands = WritableSystemInjector.removeCommands(fileName: "c76e9e25.0")
        #expect(commands.first == "remount")
        let unmounts = try #require(commands.first { $0.contains("nsenter --mount=") })
        #expect(unmounts.contains("umount /system/etc/security/cacerts"))
        #expect(unmounts.contains("umount /apex/com.android.conscrypt/cacerts"))
        #expect(commands.contains { $0 == "rm -f /system/etc/security/cacerts/c76e9e25.0" })
        #expect(commands.contains { $0 == "rm -r \(WritableSystemInjector.scriptDirectory)" })
    }

    @Test func reapplyCommandRunsTheScriptLeftByTheInstall() {
        #expect(WritableSystemInjector.reapplyCommand() == "sh /data/local/tmp/capture-ca/service.sh")
        #expect(WritableSystemInjector.reapplyCommand(module: Self.staging) == "sh \(Self.staging)/service.sh")
    }

    @Test func commandsRunAsTheyAreThroughOneShellEach() {
        let commands = WritableSystemInjector.installCommands(fileName: "c76e9e25.0", staging: Self.staging)
            + WritableSystemInjector.removeCommands(fileName: "c76e9e25.0")
        #expect(commands.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
    }

    @Test func verifiedInstallLeavesTheEntryInPlace() async throws {
        let guest = RecordingGuest { _ in Self.listing }
        let installation = try await WritableSystemInjector().install(Self.certificate(), adb: guest)
        #expect(installation.backend == .writableSystem)
        #expect(!guest.ran.contains { $0.contains("rm -f /system/etc/security/cacerts/c76e9e25.0") })
    }

    @Test func failedVerifyRemovesTheEntryItJustWrote() async throws {
        // An entry left on the system image stays trusted across restarts with
        // no record and no way for the user to take it out.
        let guest = RecordingGuest { _ in "" }
        let error = await #expect(throws: MandroidKitError.self) {
            _ = try await WritableSystemInjector().install(Self.certificate(), adb: guest)
        }
        #expect(error == .adb("The certificate store entry was not visible after install."))
        #expect(guest.ran.contains { $0.contains("rm -f /system/etc/security/cacerts/c76e9e25.0") })
    }

    @Test func entryNotVisibleToAppsAlsoRemovesTheEntry() async throws {
        // The shell listing shows the entry while zygote's namespace does not:
        // apps would not trust the CA, and the failure must not leave the entry
        // behind either.
        let guest = RecordingGuest { command in
            command.contains("pidof zygote64") ? "" : Self.listing
        }
        let error = await #expect(throws: MandroidKitError.self) {
            _ = try await WritableSystemInjector().install(Self.certificate(), adb: guest)
        }
        #expect(error == .adb("The certificate store entry is present but not visible in an app namespace."))
        #expect(guest.ran.contains { $0.contains("rm -f /system/etc/security/cacerts/c76e9e25.0") })
    }

    @Test func recordIsRebuiltOnlyWhenEveryConditionHolds() {
        let installation = captureInstallation(backend: .writableSystem)
        #expect(shouldReapply(installation))
        // A session started without the writable-system flag cannot hold the
        // entry, whatever the preference says now.
        #expect(!shouldReapply(installation, writableSystem: false))
        // The feature was turned off after the record was written.
        #expect(!shouldReapply(installation, captureCertificateEnabled: false))
        // The store is rebuilt through a plain shell, which only a session
        // whose shell is root offers.
        #expect(!shouldReapply(installation, capabilities: .kernelSUShellRoot))
        #expect(!shouldReapply(installation, capabilities: .none))
    }

    @Test func otherRecordsAndNoRecordAreNotReapplied() {
        #expect(!shouldReapply(captureInstallation(backend: .kernelSUModule)))
        #expect(!shouldReapply(nil))
        #expect(!shouldWant(captureInstallation(backend: .kernelSUModule)))
        #expect(!shouldWant(nil))
    }

    @Test func theAttemptIsDecidedWithoutTouchingTheGuest() {
        let installation = captureInstallation(backend: .writableSystem)
        #expect(shouldWant(installation))
        #expect(!shouldWant(installation, writableSystem: false))
        #expect(!shouldWant(installation, captureCertificateEnabled: false))
    }

    private func shouldWant(_ installation: CaptureInstallation?, writableSystem: Bool = true,
                            captureCertificateEnabled: Bool = true) -> Bool {
        WritableSystemInjector.wantsReapply(installation,
                                            launchOptions: launchOptions(writableSystem: writableSystem),
                                            captureCertificateEnabled: captureCertificateEnabled)
    }

    private func shouldReapply(_ installation: CaptureInstallation?, writableSystem: Bool = true,
                               captureCertificateEnabled: Bool = true,
                               capabilities: GuestSessionCapabilities = .adbRoot) -> Bool {
        WritableSystemInjector.shouldReapply(installation,
                                             launchOptions: launchOptions(writableSystem: writableSystem),
                                             captureCertificateEnabled: captureCertificateEnabled,
                                             capabilities: capabilities)
    }

    private func launchOptions(writableSystem: Bool) -> EmulatorLaunchOptions {
        var options = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        options.writableSystem = writableSystem
        return options
    }

    private func captureInstallation(backend: CaptureBackend) -> CaptureInstallation {
        CaptureInstallation(fileName: "c76e9e25.0", subject: "Capture CA", notAfter: Date(),
                            backend: backend, installedAt: Date())
    }
}
