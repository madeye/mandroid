import Foundation

/// Installs the certificate as a KernelSU module and applies it to the running
/// session, so a rooted guest picks it up without a restart.
public struct KernelSUModuleInjector: CertificateInjecting {
    public init() {}

    /// The guest commands that install the module, in order, run as root: copy
    /// the staged files into the module directory, apply the service script to
    /// the running session so no restart is needed, and remove the staging
    /// directory. They are one literal so the acceptance script can read the
    /// commands it runs out of this file, the way it reads the module text.
    public static func installCommands(fileName: String, staging: String,
                                       module: String = GuestTrustStore.moduleDirectory) -> [String] {
        """
        mkdir -p \(module) && cp \(staging)/* \(module)/ && chown -R root:root \(module) && chmod 755 \(module)/service.sh && chmod 644 \(module)/module.prop \(module)/\(fileName)
        sh \(module)/service.sh
        rm -r \(staging)
        """
        .split(separator: "\n").map(String.init)
    }

    public func install(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        let staging = "/data/local/tmp/capture-ca-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(GuestTrustStore.moduleProperties().utf8).write(to: directory.appendingPathComponent("module.prop"))
        let script = directory.appendingPathComponent("service.sh")
        try Data(GuestTrustStore.serviceScript().utf8).write(to: script)
        _ = try await Subprocess.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["755", script.path])
        try Data(certificate.pem.utf8).write(to: directory.appendingPathComponent(certificate.storeFileName))

        _ = try await adb.run(["push", directory.path, staging])
        let installation = CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                               notAfter: certificate.notAfter, backend: .kernelSUModule, installedAt: Date())
        do {
            // The same commands the acceptance script renders out of this file.
            for command in Self.installCommands(fileName: certificate.storeFileName, staging: staging) {
                _ = try await adb.shell("su -c '\(command)'")
            }
            let state = try await verify(installation, adb: adb)
            try state.requireVisibleAfterInstall()
            return installation
        } catch {
            // A module left behind would re-trust the CA at every boot with no
            // record of it and no way for the user to take it out. The removal
            // procedure is the instrument that clears it again.
            _ = try? await adb.shell("su -c '\(GuestTrustStore.removeScript(fileName: certificate.storeFileName))'")
            throw error
        }
    }

    public func verify(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws -> VerificationState {
        let shellListing = try await adb.shell("su -c '\(GuestTrustStore.verifyCommand(fileName: installation.fileName))'")
        // A listing that cannot be taken reads as the entry not reaching apps,
        // which is a state to report, not an adb failure to hide behind.
        let appListing = (try? await adb.shell("su -c '\(GuestTrustStore.zygoteVerifyCommand(fileName: installation.fileName))'")) ?? ""
        return GuestTrustStore.parseVerification(shellListing: shellListing, appListing: appListing,
                                                 fileName: installation.fileName)
    }

    public func remove(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws {
        // The record decides what comes out: its entry name is what the removal
        // is rendered from. The module identifier stays a constant because one
        // session holds one capture module.
        guard installation.backend == .kernelSUModule else {
            throw MandroidKitError.adb("The recorded certificate was not installed as a KernelSU module.")
        }
        _ = try await adb.shell("su -c '\(GuestTrustStore.removeScript(fileName: installation.fileName))'")
    }
}
