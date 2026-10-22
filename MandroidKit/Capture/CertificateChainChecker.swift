import Foundation
import Security

public enum ChainVerdict: Sendable, Equatable {
    /// The proxy's leaf chains to the certificate we are about to install.
    case trusted
    /// The proxy signs with a different CA; the associated value is that CA's subject.
    case foreignIssuer(String)
    /// The chain verifies against this Mac's own trust settings without our
    /// anchor: either the proxy is not intercepting, or it signs with a CA this
    /// Mac already trusts and not with the chosen one.
    case notIntercepted
    case unreachable(String)
}

public struct CertificateChainChecker: Sendable {
    public typealias AnchorEvaluation = @Sendable ([Data]) -> Bool

    private let probe: any ProxyProbing
    private let canaryHost: String
    private let systemTrusted: AnchorEvaluation

    public init(probe: any ProxyProbing,
                canaryHost: String = CertificateAuthorityResolver.canaryHost,
                systemTrusted: @escaping AnchorEvaluation = CertificateChainChecker.evaluatesWithSystemAnchors) {
        self.probe = probe
        self.canaryHost = canaryHost
        self.systemTrusted = systemTrusted
    }

    public func evaluate(certificate: CaptureCertificate) async -> ChainVerdict {
        let chain: [Data]
        do {
            chain = try await probe.presentedChain(host: canaryHost)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard !chain.isEmpty else { return .unreachable("The proxy presented no certificate.") }
        // The anchor decides first: a debugging CA can also be installed in the host's
        // keychain, and interception must still read as interception then.
        if verifies(chain: chain, anchors: [certificate.der]) { return .trusted }
        if systemTrusted(chain) { return .notIntercepted }
        return .foreignIssuer(issuerSubject(of: chain) ?? "an issuer this check could not name")
    }

    /// A handshake yields DER; PEM is accepted too, since a chain assembled from a
    /// certificate file the user holds arrives in that encoding.
    private static func secCertificate(from data: Data) -> SecCertificate? {
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) { return certificate }
        guard let pem = CertificateImporter.firstPEMBlock(in: String(decoding: data, as: UTF8.self)),
              let der = CertificateImporter.der(fromPEM: pem) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// The chain of trust exactly as presented, leaf first and with no anchors of its
    /// own: each caller sets the roots it means to accept. The whole chain goes in
    /// because a proxy may sign the leaf with an intermediate, which cannot be
    /// verified from the leaf alone.
    private static func trust(for chain: [Data]) -> SecTrust? {
        let presented = chain.compactMap(secCertificate(from:))
        guard !presented.isEmpty else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(presented as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess else { return nil }
        return trust
    }

    private func verifies(chain: [Data], anchors: [Data]) -> Bool {
        var anchorCertificates: [SecCertificate] = []
        for der in anchors {
            guard let anchor = Self.secCertificate(from: der) else { return false }
            anchorCertificates.append(anchor)
        }
        guard let trust = Self.trust(for: chain) else { return false }
        SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// The issuer's name, either way the handshake can show it: the subject of
    /// the issuer certificate when the chain carries one, or the issuer name
    /// the leaf states when the proxy sent the leaf alone.
    private func issuerSubject(of chain: [Data]) -> String? {
        if chain.count >= 2, let der = chain.last, let certificate = Self.secCertificate(from: der) {
            return SecCertificateCopySubjectSummary(certificate) as String?
        }
        guard let der = chain.first, let leaf = Self.secCertificate(from: der) else { return nil }
        return Self.issuerName(of: leaf)
    }

    /// The common name of the issuer a certificate names for itself, which is
    /// what a subject summary of the issuer certificate would have shown.
    private static func issuerName(of certificate: SecCertificate) -> String? {
        let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [CFString: Any]
        guard let entry = values?[kSecOIDX509V1IssuerName] as? [CFString: Any],
              let components = entry[kSecPropertyKeyValue] as? [[CFString: Any]] else { return nil }
        for component in components {
            if let label = component[kSecPropertyKeyLabel] as? String, label == "2.5.4.3",
               let value = component[kSecPropertyKeyValue] as? String {
                return value
            }
        }
        return nil
    }

    /// Default anchor evaluation: the system's own trust settings, no custom anchors.
    public static let evaluatesWithSystemAnchors: AnchorEvaluation = { chain in
        guard let trust = CertificateChainChecker.trust(for: chain) else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
