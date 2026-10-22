import Foundation
import Security

/// A certificate authority the user has chosen to trust inside the guest.
public struct CaptureCertificate: Sendable, Equatable {
    public let der: Data
    public let pem: String
    public let subject: String
    public let notBefore: Date
    public let notAfter: Date
    /// Store entry name: the certificate's subject hash plus ".0".
    public let storeFileName: String
}

public enum CertificateImportError: Error, LocalizedError, Sendable {
    case unreadableFile(URL)
    case notACertificate
    case notACertificateAuthority
    case noCertificateInText
    case hashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let url): "Could not read \(url.lastPathComponent)."
        case .notACertificate: "That file is not a certificate."
        case .notACertificateAuthority: "That certificate is not a certificate authority. Choose the root CA your proxy uses to sign."
        case .noCertificateInText: "No PEM certificate found in the pasted text."
        case .hashFailed(let detail): "Could not compute the certificate store name: \(detail)"
        }
    }
}

public enum CertificateImporter {
    public static func certificate(fromFile url: URL) async throws -> CaptureCertificate {
        guard let data = try? Data(contentsOf: url) else { throw CertificateImportError.unreadableFile(url) }
        if let pem = firstPEMBlock(in: String(decoding: data, as: UTF8.self)), let der = der(fromPEM: pem) {
            return try await make(fromDER: der)
        }
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            return try await make(fromDER: SecCertificateCopyData(certificate) as Data)
        }
        // DER files are not always importable directly; retry through OpenSSL.
        guard let der = try await convertToDER(data) else { throw CertificateImportError.notACertificate }
        return try await make(fromDER: der)
    }

    public static func certificate(fromPastedText text: String) async throws -> CaptureCertificate {
        guard let pem = firstPEMBlock(in: text), let der = der(fromPEM: pem) else {
            throw CertificateImportError.noCertificateInText
        }
        return try await make(fromDER: der)
    }

    static func make(fromDER der: Data) async throws -> CaptureCertificate {
        guard let sec = SecCertificateCreateWithData(nil, der as CFData) else { throw CertificateImportError.notACertificate }
        let pem = pem(fromDER: der)
        guard try await isCertificateAuthority(pem: pem) else { throw CertificateImportError.notACertificateAuthority }
        let values = SecCertificateCopyValues(sec, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any]
        return CaptureCertificate(
            der: der,
            pem: pem,
            subject: (SecCertificateCopySubjectSummary(sec) as String?) ?? "Unnamed certificate",
            notBefore: date(in: values, oid: kSecOIDX509V1ValidityNotBefore) ?? .distantPast,
            notAfter: date(in: values, oid: kSecOIDX509V1ValidityNotAfter) ?? .distantFuture,
            storeFileName: try await storeFileName(pem: pem))
    }

    static func storeFileName(pem: String) async throws -> String {
        let result = try await runOpenSSL(on: Data(pem.utf8), named: "certificate.pem",
                                          options: ["-subject_hash_old", "-noout"])
        let hash = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, hash.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil else {
            throw CertificateImportError.hashFailed(result.status == 0 ? "unexpected output \(hash)" : result.stderrText)
        }
        return "\(hash).0"
    }

    static func isCertificateAuthority(pem: String) async throws -> Bool {
        let result = try await runOpenSSL(on: Data(pem.utf8), named: "certificate.pem",
                                          options: ["-noout", "-text"])
        guard result.status == 0 else { throw CertificateImportError.notACertificate }
        // Only the CA: line of the basic constraints extension decides; text elsewhere
        // in the dump, such as a subject that reads "CA:TRUE", must not.
        let lines = result.stdoutText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.firstIndex(where: { $0.hasPrefix("X509v3 Basic Constraints") }) else { return false }
        let value = lines[lines.index(after: header)...]
            .prefix { !$0.hasPrefix("X509v3 ") }
            .first { $0.hasPrefix("CA:") }?
            .dropFirst("CA:".count)
            .trimmingCharacters(in: .whitespaces)
        // A path length constraint follows the value, as in "CA:TRUE, pathlen:0".
        return value?.split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("TRUE") == .orderedSame
    }

    static func date(in values: [CFString: Any]?, oid: CFString) -> Date? {
        guard let entry = values?[oid] as? [CFString: Any], let time = entry[kSecPropertyKeyValue] as? CFAbsoluteTime else { return nil }
        return Date(timeIntervalSinceReferenceDate: time)
    }

    static func firstPEMBlock(in text: String) -> String? {
        guard let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    static func der(fromPEM pem: String) -> Data? {
        let body = pem.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    }

    static func pem(fromDER der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func convertToDER(_ data: Data) async throws -> Data? {
        let result = try await runOpenSSL(on: data, named: "input.cer", options: ["-outform", "der"])
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    /// Writes `contents` into a fresh temporary directory, runs `/usr/bin/openssl x509`
    /// on it with `options`, and removes the directory again before returning. Output
    /// travels through the process streams so nothing outlives the call.
    private static func runOpenSSL(on contents: Data, named name: String, options: [String]) async throws -> SubprocessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try contents.write(to: file)
        return try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/openssl"),
                                        arguments: ["x509", "-in", file.path] + options)
    }
}
