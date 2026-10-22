import Foundation
import Testing
@testable import MandroidKit

@Suite struct CaptureCertificateTests {
    @Test func storeFileNameUsesOpenSSLSubjectHash() async throws {
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(certificate.storeFileName == "c76e9e25.0")
    }

    @Test func importReadsSubjectAndValidity() async throws {
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(certificate.subject.contains("Mandroid Test CA"))
        #expect(certificate.notAfter > Date())
        #expect(certificate.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(certificate.der.isEmpty == false)
    }

    @Test func importRejectsCertificateWithoutCAConstraint() async throws {
        await #expect(throws: CertificateImportError.self) {
            _ = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-leaf.pem"))
        }
    }

    @Test func pastedTextAcceptsPEMWithSurroundingNoise() async throws {
        let pem = try Fixtures.text("test-ca.pem")
        let certificate = try await CertificateImporter.certificate(fromPastedText: "see below\n\n\(pem)\n(end)")
        #expect(certificate.storeFileName == "c76e9e25.0")
    }

    @Test func pastedTextWithoutCertificateFails() async {
        await #expect(throws: CertificateImportError.self) {
            _ = try await CertificateImporter.certificate(fromPastedText: "no certificate here")
        }
    }
}
