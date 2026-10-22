import Foundation

/// Produces the pre-flight verdict for a certificate. The probe and the
/// checker for the proxy endpoint the user gave are built outside the
/// controller and closed over here, so no endpoint travels through it.
public typealias VerdictProvider = @Sendable (CaptureCertificate) async -> ChainVerdict

/// A pre-flight verdict that stopped the install before the guest was touched.
/// The verdict is carried whole so the caller can explain which condition it
/// saw instead of reading it out of a message.
public enum CapturePreflightError: Error, LocalizedError, Equatable, Sendable {
    case verdict(ChainVerdict)

    public var errorDescription: String? {
        switch self {
        case .verdict(.trusted):
            return "The proxy's certificate chain is trusted."
        case .verdict(.foreignIssuer(let subject)):
            return "The proxy signs with \(subject), not with the certificate you chose."
        case .verdict(.notIntercepted):
            return "The chain the proxy presented is one this Mac already trusts, so either the proxy is not intercepting traffic or it signs with a different CA than the one you chose. The certificate was not installed."
        case .verdict(.unreachable(let reason)):
            return "Could not reach the proxy to check its certificate: \(reason)"
        }
    }
}

/// Why an install cannot start while the guest's one record is taken.
public enum CaptureInstallError: Error, LocalizedError, Equatable, Sendable {
    case alreadyInstalled(CaptureInstallation)

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let installation):
            return "A certificate is already installed for this virtual device (\(installation.subject)). Remove it first."
        }
    }
}

/// What the controller knows about this guest's capture certificate.
public enum CaptureControllerState: Sendable, Equatable {
    case idle
    case installed(CaptureInstallation)
    case unavailable(String)
}

extension CaptureControllerState {
    /// What one record accounts for: the installation it names, nothing when
    /// there is none, or why it could not be read. The record is the only
    /// account of what the guest holds, so a record that cannot be read is
    /// reported rather than read as nothing.
    public init(store: CaptureCertificateStore) {
        do {
            self = try store.load().map(CaptureControllerState.installed) ?? .idle
        } catch {
            self = .unavailable(error.localizedDescription)
        }
    }
}

/// Sequences a certificate install for one guest: pre-flight verdict,
/// injector, record. The verdict provider and the injector are both
/// injected, so the controller itself reaches neither a proxy nor a device.
public actor CaptureCertificateController {
    private let store: CaptureCertificateStore
    private let injector: any CertificateInjecting
    private let verdictProvider: VerdictProvider

    public private(set) var state: CaptureControllerState

    public init(store: CaptureCertificateStore,
                injector: any CertificateInjecting,
                verdict: @escaping VerdictProvider) {
        self.store = store
        self.injector = injector
        self.verdictProvider = verdict
        self.state = CaptureControllerState(store: store)
    }

    /// Runs the verdict first: anything other than `.trusted` throws without
    /// touching the guest. Otherwise the injector installs the certificate and
    /// the record is written.
    public func install(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        try refuseWhileARecordExists()
        let verdict = await verdictProvider(certificate)
        guard verdict == .trusted else { throw CapturePreflightError.verdict(verdict) }
        return try await inject(certificate, adb: adb)
    }

    /// Installs a certificate the user confirmed by hand, consulting no verdict
    /// provider at all, so a guest whose proxy cannot be reached can still be
    /// given a certificate. The caller owns telling the user that nothing was
    /// verified; everything after the verdict is the same as `install`.
    public func installUnverified(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        try refuseWhileARecordExists()
        return try await inject(certificate, adb: adb)
    }

    /// The store holds exactly one installation, so an install while one is
    /// recorded would strand the only certificate the user can still remove.
    /// Nothing touches the guest in that case.
    private func refuseWhileARecordExists() throws {
        if let existing = try store.load() {
            throw CaptureInstallError.alreadyInstalled(existing)
        }
    }

    /// The half both install paths share. The injector leaves the certificate
    /// live and verified where apps read it, so the record write is the only
    /// remaining step; if it cannot land, the installation is taken back out
    /// before the error goes on, so the guest and the record never disagree.
    private func inject(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation {
        let installation = try await injector.install(certificate, adb: adb)
        do {
            try store.save(installation)
        } catch {
            _ = try? await injector.remove(installation, adb: adb)
            throw error
        }
        state = .installed(installation)
        return installation
    }

    /// Takes the recorded certificate back out of the guest and forgets it.
    public func remove(adb: any GuestCommandRunning) async throws {
        if let installation = try store.load() {
            try await injector.remove(installation, adb: adb)
        }
        try store.clear()
        state = .idle
    }
}
