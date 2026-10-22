import Foundation

public enum ResolverOutcome: Sendable {
    case found(CaptureCertificate, via: String)
    case failed([String])
}

/// Automatic acquisition. Manual file selection and pasted PEM do not come
/// through here; they need no proxy.
public struct CertificateAuthorityResolver: Sendable {
    /// Endpoints that debugging proxies answer themselves.
    public static let wellKnownEndpoints: [URL] = [
        URL(string: "http://mitm.it/cert/pem")!,
        URL(string: "http://chls.pro/ssl")!,
    ]

    public static let canaryHost = "example.com"

    private let probe: any ProxyProbing

    public init(probe: any ProxyProbing) {
        self.probe = probe
    }

    public func certificate() async -> ResolverOutcome {
        var reasons: [String] = []

        for url in Self.wellKnownEndpoints {
            do {
                let response = try await probe.fetch(url)
                guard response.status == 200, let pem = CertificateImporter.firstPEMBlock(in: String(decoding: response.body, as: UTF8.self)),
                      let der = CertificateImporter.der(fromPEM: pem) else {
                    reasons.append("\(url.host ?? url.absoluteString) did not return a certificate")
                    continue
                }
                return .found(try await CertificateImporter.make(fromDER: der), via: url.absoluteString)
            } catch {
                reasons.append("\(url.host ?? url.absoluteString): \(error.localizedDescription)")
            }
        }

        do {
            let chain = try await probe.presentedChain(host: Self.canaryHost)
            guard chain.count >= 2 else {
                reasons.append("the proxy sends only a leaf certificate, so the signing CA cannot be derived")
                return .failed(reasons)
            }
            guard let issuer = chain.last else {
                reasons.append("the handshake carried no issuer certificate")
                return .failed(reasons)
            }
            return .found(try await CertificateImporter.make(fromDER: issuer), via: "the TLS chain for \(Self.canaryHost)")
        } catch {
            reasons.append("\(Self.canaryHost): \(error.localizedDescription)")
        }

        return .failed(reasons)
    }
}
