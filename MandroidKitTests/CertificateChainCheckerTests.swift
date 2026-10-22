import Foundation
import Testing
@testable import MandroidKit

private struct ChainStubProbe: ProxyProbing {
    let chain: [Data]
    let failure: Error?

    init(chain: [Data] = [], failure: Error? = nil) { self.chain = chain; self.failure = failure }

    func fetch(_ url: URL) async throws -> ProxyHTTPResponse { throw MandroidKitError.adb("unused") }
    func presentedChain(host: String) async throws -> [Data] {
        if let failure { throw failure }
        return chain
    }
}

@Suite struct CertificateChainCheckerTests {
    @Test func leafSignedByProvidedCAIsTrusted() async throws {
        let ca = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        let probe = ChainStubProbe(chain: [try Fixtures.data("test-leaf.pem")])
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in false })
            .evaluate(certificate: ca)
        #expect(verdict == .trusted)
    }

    @Test func leafFromAnotherCAIsForeign() async throws {
        let other = try await CertificateImporter.certificate(fromFile: Fixtures.url("other-ca.pem"))
        let probe = ChainStubProbe(chain: [try Fixtures.data("test-leaf.pem"), try Fixtures.data("test-ca.pem")])
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in false })
            .evaluate(certificate: other)
        #expect(verdict == .foreignIssuer("Mandroid Test CA"))
    }

    @Test func leafAloneStillNamesTheIssuer() async throws {
        // A proxy that sends only the leaf still names its issuer in the leaf
        // itself, so the verdict names the CA either way the handshake carries
        // it.
        let other = try await CertificateImporter.certificate(fromFile: Fixtures.url("other-ca.pem"))
        let probe = ChainStubProbe(chain: [try Fixtures.data("test-leaf.pem")])
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in false })
            .evaluate(certificate: other)
        #expect(verdict == .foreignIssuer("Mandroid Test CA"))
    }

    @Test func chainThatTheSystemAlreadyTrustsIsNotIntercepted() async throws {
        // The chain is signed by test-ca, so the anchor under test must be a
        // different CA: "system-trusted and not signed by the chosen CA" is
        // what no-interception looks like.
        let other = try await CertificateImporter.certificate(fromFile: Fixtures.url("other-ca.pem"))
        let probe = ChainStubProbe(chain: [try Fixtures.data("test-leaf.pem")])
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in true })
            .evaluate(certificate: other)
        #expect(verdict == .notIntercepted)
    }

    @Test func chainSignedByTheChosenCAStaysTrustedWhenTheHostTrustsIt() async throws {
        // A debugging CA can also be installed in the Mac's keychain (an
        // enterprise root, for one). The anchor comparison decides first, so
        // interception is still reported as trusted.
        let ca = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        let probe = ChainStubProbe(chain: [try Fixtures.data("test-leaf.pem")])
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in true })
            .evaluate(certificate: ca)
        #expect(verdict == .trusted)
    }

    @Test func unreachableProxyIsReported() async throws {
        let ca = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        let probe = ChainStubProbe(failure: MandroidKitError.adb("connection refused"))
        let verdict = await CertificateChainChecker(probe: probe, systemTrusted: { _ in false })
            .evaluate(certificate: ca)
        guard case .unreachable(let reason) = verdict else {
            Issue.record("expected unreachable, got \(verdict)"); return
        }
        #expect(reason.contains("connection refused"))
    }
}
