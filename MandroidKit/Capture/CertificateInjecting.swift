import Foundation

/// How a certificate reaches the guest trust store.
public enum CaptureBackend: String, Codable, Sendable {
    case kernelSUModule
    case writableSystem
}

/// A certificate this Mac put into the guest, recorded so it can be checked
/// and taken out again after a restart.
public struct CaptureInstallation: Codable, Sendable, Equatable {
    public let fileName: String
    public let subject: String
    public let notAfter: Date
    public let backend: CaptureBackend
    public let installedAt: Date
}

/// The guest command surface an injector runs: root shell commands and raw
/// `adb` arguments. `ADBClient` is the live implementation; a test stands in
/// for it to see what a procedure would run without reaching a device.
public protocol GuestCommandRunning: Sendable {
    func shell(_ command: String, timeout: Duration) async throws -> String
    func run(_ args: [String], timeout: Duration) async throws -> String
}

extension ADBClient: GuestCommandRunning {}

extension GuestCommandRunning {
    @discardableResult
    public func shell(_ command: String) async throws -> String {
        try await shell(command, timeout: .seconds(30))
    }

    @discardableResult
    public func run(_ args: [String]) async throws -> String {
        try await run(args, timeout: .seconds(30))
    }
}

/// The install path for one guest. Implementations own the guest-side
/// procedure; callers only sequence install, verify and remove.
public protocol CertificateInjecting: Sendable {
    func install(_ certificate: CaptureCertificate, adb: any GuestCommandRunning) async throws -> CaptureInstallation
    func verify(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws -> VerificationState
    func remove(_ installation: CaptureInstallation, adb: any GuestCommandRunning) async throws
}
