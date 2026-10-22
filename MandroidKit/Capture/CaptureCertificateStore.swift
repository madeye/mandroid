import Foundation

/// The record of the capture certificate this Mac put into one guest, kept
/// next to the other per-AVD state so a later session can check it and take it
/// out again. The root is supplied by the caller; this file only names the
/// entry inside it.
public struct CaptureCertificateStore: Sendable {
    private let file: URL

    public init(root: URL) { file = root.appendingPathComponent("capture-certificate.json") }

    /// The recorded installation, or nil when nothing was recorded yet.
    public func load() throws -> CaptureInstallation? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CaptureInstallation.self, from: Data(contentsOf: file))
    }

    public func save(_ installation: CaptureInstallation) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installation).write(to: file, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
