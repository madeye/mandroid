import Foundation
import Testing
@testable import MandroidKit

private struct StubProbe: ProxyProbing {
    var responses: [String: ProxyHTTPResponse] = [:]
    var chains: [String: [Data]] = [:]
    var error: Error?

    func fetch(_ url: URL) async throws -> ProxyHTTPResponse {
        if let error { throw error }
        guard let response = responses[url.absoluteString] else { throw MandroidKitError.adb("no stub response") }
        return response
    }

    func presentedChain(host: String) async throws -> [Data] {
        if let error { throw error }
        return chains[host] ?? []
    }
}

@Suite struct CertificateAuthorityResolverTests {
    private func caDER() async throws -> Data {
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        return certificate.der
    }

    @Test func wellKnownEndpointWins() async throws {
        let der = try await caDER()
        let pem = String(decoding: try Fixtures.data("test-ca.pem"), as: UTF8.self)
        let probe = StubProbe(responses: [CertificateAuthorityResolver.wellKnownEndpoints[0].absoluteString:
                                            ProxyHTTPResponse(status: 200, body: Data(pem.utf8), contentType: "application/x-pem-file")])
        let outcome = await CertificateAuthorityResolver(probe: probe).certificate()
        guard case .found(let certificate, let via) = outcome else {
            Issue.record("expected a certificate, got \(outcome)"); return
        }
        #expect(certificate.der == der)
        #expect(via == CertificateAuthorityResolver.wellKnownEndpoints[0].absoluteString)
    }

    @Test func issuerComesFromChainWhenNoEndpointAnswers() async throws {
        let ca = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        let probe = StubProbe(chains: [CertificateAuthorityResolver.canaryHost: [try Fixtures.data("test-leaf.pem"), ca.der]])
        let outcome = await CertificateAuthorityResolver(probe: probe).certificate()
        guard case .found(let certificate, _) = outcome else {
            Issue.record("expected a certificate, got \(outcome)"); return
        }
        #expect(certificate.storeFileName == "c76e9e25.0")
    }

    @Test func leafOnlyChainIsNotAnIssuer() async throws {
        let probe = StubProbe(chains: [CertificateAuthorityResolver.canaryHost: [try Fixtures.data("test-leaf.pem")]])
        let outcome = await CertificateAuthorityResolver(probe: probe).certificate()
        guard case .failed(let reasons) = outcome else {
            Issue.record("expected failure, got \(outcome)"); return
        }
        #expect(reasons.count == CertificateAuthorityResolver.wellKnownEndpoints.count + 1)
    }
}
