import Foundation

/// Installs the certificate on a `userdebug` session booted with a writable
/// system partition: `adb root` makes the shell itself root, the system
/// partition is remounted writable, and the entry is written straight into the
/// system store. No KernelSU module is involved, so nothing is installed under
/// `/data/adb`. The entry stays on the AVD's system image across a restart, but
/// the tmpfs store and its binds do not, which is why a session start runs the
/// script left behind to rebuild them.
public struct WritableSystemInjector: CertificateInjecting {
    /// Where the store script and the certificate stay between boots: the
    /// script reads the certificate from its own directory, and the re-apply
    /// runs it from here.
    public static let scriptDirectory = "/data/local/tmp/capture-ca"

    public init() {}

    /// The guest commands that install the certificate, in order, run as root
    /// through a plain shell: remount the system partition, place the script
    /// and the certificate beside each other, write the store entry with its
    /// ownership, mode and label, apply the store to the running session, and
    /// drop the staging directory. They are one literal so the acceptance
    /// script can read the commands it runs out of this file, the way it reads
    /// the module text.
    public static func installCommands(fileName: String, staging: String,
                                       module: String = scriptDirectory) -> [String] {
        """
        remount
        mkdir -p \(module) && cp \(staging)/* \(module)/ && chmod 755 \(module)/service.sh && chmod 644 \(module)/\(fileName)
        cp \(module)/\(fileName) \(GuestTrustStore.systemStore)/\(fileName)
        chown root:root \(GuestTrustStore.systemStore)/\(fileName) && chmod 644 \(GuestTrustStore.systemStore)/\(fileName)
        LABEL=$(grep -h security/cacerts /system/etc/selinux/plat_file_contexts 2>/dev/null | awk '{print $2}' | head -1); [ -n "$LABEL" ] || LABEL=u:object_r:system_security_cacerts_file:s0; chcon "$LABEL" \(GuestTrustStore.systemStore)/\(fileName)
        sh \(module)/service.sh
        rm -r \(staging)
        """
        .split(separator: "\n").map(String.init)
    }

    /// The guest commands that take the certificate out, in order: make the
    /// partition writable, take the store binds out of every mount namespace
    /// that got them, delete the entry from the system image, and drop the
    /// script directory. The unmounts are best effort: a session that never
    /// rebuilt the store has nothing to take out, which is not a failure.
    public static func removeCommands(fileName: String, module: String = scriptDirectory) -> [String] {
        """
        remount
        UMOUNT=/system/bin/umount; [ -x "$UMOUNT" ] || UMOUNT=umount; seen=""; for pid in $(ls /proc | grep -E "^[0-9]+$"); do ns="/proc/$pid/ns/mnt"; target=$(readlink "$ns" 2>/dev/null) || continue; case " $seen " in *" $target "*) continue ;; esac; seen="$seen $target"; nsenter --mount="$ns" -- "$UMOUNT" \(GuestTrustStore.systemStore) 2>/dev/null; nsenter --mount="$ns" -- "$UMOUNT" \(GuestTrustStore.apexStore) 2>/dev/null; done; umount \(GuestTrustStore.systemStore) 2>/dev/null; umount \(GuestTrustStore.apexStore) 2>/dev/null; true
        rm -f \(GuestTrustStore.systemStore)/\(fileName)
        rm -r \(module)
        """
        .split(separator: "\n").map(String.init)
    }

    /// The command that rebuilds the store from the files `install` left in the
    /// script directory.
    public static func reapplyCommand(module: String = scriptDirectory) -> String {
        "sh \(module)/service.sh"
    }

    /// Whether a booted session and its record ask for the rebuild at all,
    /// none of which needs the guest: the record is a writable-system install,
    /// the session was launched with the writable-system flag (the running
    /// session's options, not the preference as it reads now), and the capture
    /// feature is still on.
    public static func wantsReapply(_ installation: CaptureInstallation?,
                                    launchOptions: EmulatorLaunchOptions,
                                    captureCertificateEnabled: Bool) -> Bool {
        guard launchOptions.writableSystem, captureCertificateEnabled else { return false }
        return installation?.backend == .writableSystem
    }

    /// Whether the store can actually be rebuilt on this session: it wants the
    /// rebuild and its shell is root, which the writable-system procedure needs
    /// because it runs through a plain shell.
    public static func shouldReapply(_ installation: CaptureInstallation?,
                                     launchOptions: EmulatorLaunchOptions,
                                     captureCertificateEnabled: Bool,
                                     capabilities: GuestSessionCapabilities) -> Bool {
        wantsReapply(installation, launchOptions: launchOptions,
                     captureCertificateEnabled: captureCertificateEnabled)
            && capabilities.shouldReapply(installation)
    }

    public func install(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        let staging = "/data/local/tmp/capture-ca-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("service.sh")
        try Data(GuestTrustStore.serviceScript().utf8).write(to: script)
        _ = try await Subprocess.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["755", script.path])
        try Data(certificate.pem.utf8).write(to: directory.appendingPathComponent(certificate.storeFileName))

        // The store is written by the shell itself, so the daemon has to run as
        // root before anything is pushed or run.
        _ = try await adb.run(["root"])
        _ = try await adb.run(["wait-for-device"])
        _ = try await adb.run(["push", directory.path, staging])
        let installation = CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                               notAfter: certificate.notAfter, backend: .writableSystem, installedAt: Date())
        do {
            // The same commands the acceptance script renders out of this file.
            for command in Self.installCommands(fileName: certificate.storeFileName, staging: staging) {
                _ = try await adb.shell(command)
            }
            let state = try await verify(installation, adb: adb)
            try state.requireVisibleAfterInstall()
            return installation
        } catch {
            // An entry left on the system image would stay trusted across
            // restarts with no record of it and no way for the user to take it
            // out. The removal procedure is what clears it again.
            for command in Self.removeCommands(fileName: certificate.storeFileName) {
                _ = try? await adb.shell(command)
            }
            throw error
        }
    }

    public func verify(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws -> VerificationState {
        // The shell is root on this session shape, so the listing needs no `su`.
        let shellListing = try await adb.shell(GuestTrustStore.verifyCommand(fileName: installation.fileName))
        // A listing that cannot be taken reads as the entry not reaching apps,
        // which is a state to report, not an adb failure to hide behind.
        let appListing = (try? await adb.shell(GuestTrustStore.zygoteVerifyCommand(fileName: installation.fileName))) ?? ""
        return GuestTrustStore.parseVerification(shellListing: shellListing, appListing: appListing,
                                                 fileName: installation.fileName)
    }

    public func remove(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws {
        _ = try await adb.run(["root"])
        _ = try await adb.run(["wait-for-device"])
        for command in Self.removeCommands(fileName: installation.fileName) {
            _ = try await adb.shell(command)
        }
    }

    /// Switches the daemon to root and reports what the shell then offers: a
    /// `userdebug` image accepts the switch, anything else stays as it is and
    /// the capabilities say so. A session cannot carry this shape's runtime
    /// store without it, because the store is rebuilt through a plain shell.
    public func activateRoot(adb: ADBClient) async -> GuestSessionCapabilities {
        _ = try? await adb.run(["root"])
        _ = try? await adb.run(["wait-for-device"])
        return await GuestSessionCapabilities.detect(adb: adb)
    }

    /// Rebuilds the store on a session that has just booted: the entry is still
    /// on the system image, the tmpfs store and its binds are gone.
    public func reapply(_ installation: CaptureInstallation, adb: ADBClient) async throws {
        _ = try await adb.run(["root"])
        _ = try await adb.run(["wait-for-device"])
        _ = try await adb.shell(Self.reapplyCommand())
    }
}
