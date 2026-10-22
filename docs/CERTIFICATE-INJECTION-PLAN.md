# Capture certificate injection — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/CERTIFICATE-INJECTION.md`. Read it before starting; it records the
measurements this plan depends on.

**Goal:** Let a user hand Mandroid a debugging proxy's root CA and make guest apps
trust it, on KernelSU-rooted sessions and on writable-system (`google_apis`)
sessions.

**Architecture:** Host-side Swift types obtain and validate the CA, render a
KernelSU module or a direct system-store write, drive it over the existing
`ADBClient`, verify the store from the guest, and record the installation per
AVD. No new SwiftPM dependency: certificate hashing shells out to
`/usr/bin/openssl` (same convention as `/usr/bin/unzip` and `/usr/bin/ditto`),
TLS inspection uses `URLSession` plus `Security`.

**Tech stack:** Swift 6 (strict concurrency), AppKit + SwiftUI, Swift Testing,
`URLSession` with `connectionProxyDictionary`, `Security` framework, `ADBClient`,
`Subprocess`, KernelSU v3.3.0 assets already vendored by `KernelSUPatcher`.

## Global constraints

- Apple silicon only, macOS 15 deployment target, Swift 6 language mode.
- SwiftPM dependencies stay at grpc-swift-2, grpc-swift-nio-transport,
  grpc-swift-protobuf, swift-protobuf. Adding a package requires a documented
  reason in DESIGN.md; this plan adds none.
- System binaries are invoked as `/usr/bin/openssl`, `/usr/bin/unzip`,
  `/usr/bin/ditto` through `Subprocess.run(_:arguments:environment:currentDirectory:stdin:)`.
- Every `emulator`/`adb` subprocess keeps the existing isolation environment
  (SDK, AVD and emulator home under the app data root, dedicated ADB server
  port). Reuse `ADBClient`; never call `adb` directly.
- Never commit on `main`. Work on `feature/capture-certificate-injection`.
- New Swift files require `xcodegen generate` before they build; `xcodegen` is
  not installed on this machine yet.
- Commit messages: imperative, sentence case, no progress vocabulary, no tool
  names, no attribution trailers.
- Docs and UI strings are English.
- Guest-side constants: module directory `/data/adb/modules/capture-ca`; store
  paths `/apex/com.android.conscrypt/cacerts` and
  `/system/etc/security/cacerts`; store entry name `<subject_hash_old>.0`.

## Prerequisites

```bash
brew install xcodegen
cd <repo>
git switch -c feature/capture-certificate-injection
xcodegen generate && xcodebuild -scheme Mandroid -configuration Debug build
```

## File map

| Path | Responsibility |
|---|---|
| `MandroidKit/Capture/CaptureCertificate.swift` | Certificate value type, import from file/paste, store file name, CA constraint check |
| `MandroidKit/Capture/ProxyProbe.swift` | HTTP and TLS fetches through a proxy endpoint; the `ProxyProbing` protocol |
| `MandroidKit/Capture/CertificateAuthorityResolver.swift` | Automatic CA acquisition strategies |
| `MandroidKit/Capture/CertificateChainChecker.swift` | Pre-flight: does the proxy sign with this CA |
| `MandroidKit/Capture/CertificateInjecting.swift` | Injector protocol and installation record type |
| `MandroidKit/Capture/GuestTrustStore.swift` | Guest command builders and output parsers, shared by injectors |
| `MandroidKit/Capture/KernelSUModuleInjector.swift` | Module rendering, install, immediate apply, verify, remove |
| `MandroidKit/Capture/WritableSystemInjector.swift` | Direct system-store write for userdebug sessions |
| `MandroidKit/Capture/CaptureCertificateStore.swift` | Per-AVD installation record on disk |
| `MandroidKit/Capture/CaptureCertificateController.swift` | Orchestration used by the UI |
| `MandroidKit/Emulator/GuestSessionCapabilities.swift` | What root level a running session offers |
| `MandroidKit/Emulator/EmulatorLaunchOptions.swift` | Modified: writable-system flag |
| `MandroidKit/KernelSU/KernelSUPatcher.swift` | Modified: optional shell root, cache keyed on it |
| `MandroidKit/Runner/RunnerSettings.swift` | Modified: capture, writable-system and image-tag preferences |
| `MandroidKit/Runner/RunnerCoordinator.swift` | Modified: injector selection, re-apply after boot |
| `MandroidKit/SDK/SDKBootstrap.swift` | Modified: image selection by tag |
| `Mandroid/Settings/SettingsView.swift` | Modified: capture section |
| `Scripts/capture-certificate-test.sh` | Runtime acceptance for both injectors |
| `MandroidKitTests/Fixtures/test-ca.pem`, `other-ca.pem`, `test-leaf.pem` | Test certificates |
| `MandroidKitTests/Capture*.swift`, `GuestTrustStoreTests.swift`, `KernelSUTests.swift` | Tests |

---

### Task 1: Certificate import and store file name

**Files:**
- Create: `MandroidKit/Capture/CaptureCertificate.swift`
- Create: `MandroidKitTests/CaptureCertificateTests.swift`
- Create fixtures: `MandroidKitTests/Fixtures/test-ca.pem`, `other-ca.pem`, `test-leaf.pem`

**Interfaces:**
- Consumes: `Subprocess.run`, `MandroidKitError` conventions.
- Produces: `CaptureCertificate` (fields `der`, `pem`, `subject`, `notBefore`, `notAfter`, `storeFileName`), `CertificateImportError`, `CertificateImporter.certificate(fromFile:)`, `CertificateImporter.certificate(fromPastedText:)`.

- [ ] **Step 1: Generate the fixtures**

Fixtures for this plan are already generated at `/tmp/mandroid-fixtures`; copy
the three `.pem` files into `MandroidKitTests/Fixtures/` and leave the `.key` and
`.csr` files behind — private keys must not enter the repository. To regenerate
instead:

```bash
openssl req -x509 -newkey rsa:2048 -keyout /tmp/test-ca.key -out test-ca.pem -days 7300 -nodes -subj "/C=US/O=Mandroid Tests/CN=Mandroid Test CA"
openssl req -newkey rsa:2048 -keyout /tmp/other-ca.key -out /tmp/other-ca.csr -nodes -subj "/C=US/O=Mandroid Tests/CN=Mandroid Other CA"
openssl req -x509 -key /tmp/other-ca.key -in /tmp/other-ca.csr -out other-ca.pem -days 7300 -subj "/C=US/O=Mandroid Tests/CN=Mandroid Other CA"
openssl req -newkey rsa:2048 -keyout /tmp/test-leaf.key -out /tmp/test-leaf.csr -nodes -subj "/CN=canary.test"
openssl x509 -req -in /tmp/test-leaf.csr -CA test-ca.pem -CAkey /tmp/test-ca.key -set_serial 4097 -days 3650 -out test-leaf.pem
openssl x509 -in test-ca.pem -noout -subject_hash_old     # must print c76e9e25
openssl x509 -in other-ca.pem -noout -subject_hash_old    # must print 94f6f293
```

- [ ] **Step 2: Write the failing tests**

`MandroidKitTests/CaptureCertificateTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -scheme Mandroid test 2>&1 | tail -20`
Expected: compile failure, `CertificateImporter` is undefined.

- [ ] **Step 4: Implement `CaptureCertificate.swift`**

```swift
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

public enum CertificateImportError: LocalizedError {
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("certificate.pem")
        try Data(pem.utf8).write(to: file)
        let result = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/openssl"),
                                             arguments: ["x509", "-in", file.path, "-subject_hash_old", "-noout"])
        let hash = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, hash.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil else {
            throw CertificateImportError.hashFailed(result.status == 0 ? "unexpected output \(hash)" : result.stderrText)
        }
        return "\(hash).0"
    }

    static func isCertificateAuthority(pem: String) async throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("certificate.pem")
        try Data(pem.utf8).write(to: file)
        let result = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/openssl"),
                                             arguments: ["x509", "-in", file.path, "-noout", "-text"])
        guard result.status == 0 else { throw CertificateImportError.notACertificate }
        return result.stdoutText.contains("CA:TRUE")
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.cer")
        let output = directory.appendingPathComponent("output.der")
        try data.write(to: input)
        let result = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/openssl"),
                                             arguments: ["x509", "-in", input.path, "-outform", "der", "-out", output.path])
        guard result.status == 0 else { return nil }
        return try? Data(contentsOf: output)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -20`
Expected: `CaptureCertificateTests` all pass, no other suite regressed.

- [ ] **Step 6: Commit**

```bash
git add MandroidKit/Capture/CaptureCertificate.swift MandroidKitTests/CaptureCertificateTests.swift MandroidKitTests/Fixtures
git commit -m "Add certificate import and store file naming"
```

---

### Task 2: Proxy probe

**Files:**
- Create: `MandroidKit/Capture/ProxyProbe.swift`
- Create: `MandroidKitTests/ProxyProbeTests.swift`

**Interfaces:**
- Consumes: `HTTPProxyEndpoint` (`host`, `port`, `androidHost`).
- Produces: `ProxyHTTPResponse`, `ProxyProbing` protocol (`fetch(_:)`, `presentedChain(host:)`), `ProxyProbe(endpoint:timeout:)`, `ProxyProbe.proxyDictionary(for:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MandroidKit

@Suite struct ProxyProbeTests {
    @Test func proxyDictionaryCarriesHTTPAndHTTPSEndpoints() throws {
        let endpoint = try HTTPProxyEndpoint(host: "127.0.0.1", port: 9001)
        let dictionary = ProxyProbe.proxyDictionary(for: endpoint)
        #expect(dictionary[kCFNetworkProxiesHTTPEnable] as? Int == 1)
        #expect(dictionary[kCFNetworkProxiesHTTPProxy] as? String == "127.0.0.1")
        #expect(dictionary[kCFNetworkProxiesHTTPPort] as? Int == 9001)
        #expect(dictionary[kCFNetworkProxiesHTTPSEnable] as? Int == 1)
        #expect(dictionary[kCFNetworkProxiesHTTPSProxy] as? String == "127.0.0.1")
        #expect(dictionary[kCFNetworkProxiesHTTPSPort] as? Int == 9001)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `ProxyProbe` undefined.

- [ ] **Step 3: Implement `ProxyProbe.swift`**

```swift
import Foundation

public struct ProxyHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String?
}

/// Everything the certificate acquisition path needs from a proxy.
public protocol ProxyProbing: Sendable {
    func fetch(_ url: URL) async throws -> ProxyHTTPResponse
    /// Certificates as presented during a TLS handshake through the proxy, leaf first.
    func presentedChain(host: String) async throws -> [Data]
}

public struct ProxyProbe: ProxyProbing {
    private let endpoint: HTTPProxyEndpoint
    private let timeout: TimeInterval

    public init(endpoint: HTTPProxyEndpoint, timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public static func proxyDictionary(for endpoint: HTTPProxyEndpoint) -> [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable: 1,
            kCFNetworkProxiesHTTPProxy: endpoint.host,
            kCFNetworkProxiesHTTPPort: endpoint.port,
            kCFNetworkProxiesHTTPSEnable: 1,
            kCFNetworkProxiesHTTPSProxy: endpoint.host,
            kCFNetworkProxiesHTTPSPort: endpoint.port,
        ]
    }

    private func session(delegate: URLSessionTaskDelegate?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = Self.proxyDictionary(for: endpoint)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func fetch(_ url: URL) async throws -> ProxyHTTPResponse {
        let (data, response) = try await session(delegate: nil).data(from: url)
        guard let http = response as? HTTPURLResponse else { throw MandroidKitError.adb("The proxy did not return an HTTP response.") }
        return ProxyHTTPResponse(status: http.statusCode, body: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    public func presentedChain(host: String) async throws -> [Data] {
        let capture = ChainCapture()
        let session = session(delegate: capture)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        let chain = await capture.certificates
        guard !chain.isEmpty else { throw MandroidKitError.adb("No TLS handshake completed through the proxy.") }
        return chain
    }
}

/// Captures the peer chain of the first server-trust challenge and cancels it.
private final class ChainCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var certificates: [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            lock.lock()
            if storage.isEmpty { storage = chain.map { SecCertificateCopyData($0) as Data } }
            lock.unlock()
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
```

`import Security` is required at the top of the file.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass. `presentedChain` is exercised against a live proxy in Task 12's script.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/Capture/ProxyProbe.swift MandroidKitTests/ProxyProbeTests.swift
git commit -m "Add proxy probe for CA retrieval and chain inspection"
```

---

### Task 3: Automatic CA acquisition

**Files:**
- Create: `MandroidKit/Capture/CertificateAuthorityResolver.swift`
- Create: `MandroidKitTests/CertificateAuthorityResolverTests.swift`

**Interfaces:**
- Consumes: `ProxyProbing`, `ProxyHTTPResponse`, `CertificateImporter.make(fromDER:)`.
- Produces: `ResolverOutcome` (`.found(CaptureCertificate, via: String)`, `.failed([String])`), `CertificateAuthorityResolver(probe:)`, `resolver.certificate()`. The resolver never takes an endpoint: the injected probe already carries the one it was built with.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `CertificateAuthorityResolver` undefined.

- [ ] **Step 3: Implement `CertificateAuthorityResolver.swift`**

```swift
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
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/Capture/CertificateAuthorityResolver.swift MandroidKitTests/CertificateAuthorityResolverTests.swift
git commit -m "Add automatic certificate acquisition through a proxy"
```

---

### Task 4: Pre-flight chain check

**Files:**
- Create: `MandroidKit/Capture/CertificateChainChecker.swift`
- Create: `MandroidKitTests/CertificateChainCheckerTests.swift`

**Interfaces:**
- Consumes: `ProxyProbing`, `CaptureCertificate`.
- Produces: `ChainVerdict` (`.trusted`, `.foreignIssuer(String)`, `.notIntercepted`, `.unreachable(String)`), `CertificateChainChecker(probe:canaryHost:systemTrusted:)`, `evaluate(certificate:)`. Like the resolver, the checker takes no endpoint — the probe it was given carries it.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

`systemTrusted` is an injected predicate so the tests never depend on the
machine's trust settings; production passes the default implementation below.
The canary host defaults to `CertificateAuthorityResolver.canaryHost`. The
anchor comparison runs first: a chain that verifies against the chosen CA is
interception regardless of what the host keychain thinks, which is what keeps
a debugging CA that is also installed on the Mac from being reported as
no-interception. Both trust objects are built by one shared private helper
that takes the presented chain leaf-first, so the verification path exists
once. The implemented file additionally tolerates PEM chain entries because
the fixtures at this seam are PEM files while `presentedChain` yields DER.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `CertificateChainChecker` undefined.

- [ ] **Step 3: Implement `CertificateChainChecker.swift`**

```swift
import Foundation
import Security

public enum ChainVerdict: Sendable, Equatable {
    /// The proxy's leaf chains to the certificate we are about to install.
    case trusted
    /// The proxy signs with a different CA; the associated value is that CA's subject.
    case foreignIssuer(String)
    /// The chain is the site's real one: this proxy is not intercepting.
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
        // The anchor comparison decides first: a chain that verifies against the
        // chosen CA is interception even when the host keychain trusts it too.
        if verifies(chain: chain, anchors: [certificate.der]) { return .trusted }
        if systemTrusted(chain) { return .notIntercepted }
        return .foreignIssuer(issuerSubject(of: chain) ?? "a CA other than the chosen certificate")
    }

    private func verifies(chain: [Data], anchors: [Data]) -> Bool {
        var anchorCertificates: [SecCertificate] = []
        for der in anchors {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return false }
            anchorCertificates.append(certificate)
        }
        guard let trust = Self.trust(for: chain) else { return false }
        SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Builds a basic-X509 trust over the presented chain, leaf first. It sets no
    /// anchors of its own: each caller supplies the roots it wants evaluated.
    private static func trust(for chain: [Data]) -> SecTrust? {
        var certificates: [SecCertificate] = []
        for der in chain {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            certificates.append(certificate)
        }
        guard !certificates.isEmpty else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess else { return nil }
        return trust
    }

    private func issuerSubject(of chain: [Data]) -> String? {
        guard let der = chain.last, chain.count >= 2,
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    /// Default anchor evaluation: the system's own trust settings, no custom anchors.
    public static let evaluatesWithSystemAnchors: AnchorEvaluation = { chain in
        guard let trust = Self.trust(for: chain) else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/Capture/CertificateChainChecker.swift MandroidKitTests/CertificateChainCheckerTests.swift
git commit -m "Add pre-flight check that the proxy signs with the chosen CA"
```

---

### Task 5: KernelSU ramdisk with optional shell root

**Files:**
- Modify: `MandroidKit/KernelSU/KernelSUPatcher.swift`
- Modify: `MandroidKit/Runner/RunnerSettings.swift`
- Modify: `MandroidKit/Runner/RunnerCoordinator.swift`
- Modify: `MandroidKitTests/KernelSUTests.swift`

**Interfaces:**
- Consumes: existing `KernelSUPatcher` assets, hashing and patch flow.
- Produces: `KernelSUPatcher.cacheDirectoryName(version:kernelHash:stockHash:allowShell:)`, `prepare(imageDirectory:allowShell:progress:)`, `Manifest.allowShell`, `RunnerSettings.captureCertificateEnabled` (persisted key `captureCertificateEnabled`).

- [ ] **Step 1: Write the failing tests**

Append to `MandroidKitTests/KernelSUTests.swift`:

```swift
@Test func cacheDirectorySeparatesShellRootedPatches() {
    let plain = KernelSUPatcher.cacheDirectoryName(version: "3.3.0", kernelHash: "aa", stockHash: "bb", allowShell: false)
    let rooted = KernelSUPatcher.cacheDirectoryName(version: "3.3.0", kernelHash: "aa", stockHash: "bb", allowShell: true)
    #expect(plain != rooted)
    #expect(plain == "v3.3.0-aa-bb")
    #expect(rooted == "v3.3.0-aa-bb-shell")
}

@Test func manifestCarriesShellRootChoice() throws {
    let manifest = KernelSUPatcher.Manifest(version: "3.3.0", kernelHash: "aa", stockRamdiskHash: "bb",
                                            patchedHash: "cc", guestToolHash: "dd", allowShell: true)
    let decoded = try JSONDecoder().decode(KernelSUPatcher.Manifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded == manifest)
    #expect(decoded.allowShell)
}

@Test func captureCertificateSettingRoundTrips() {
    let defaults = UserDefaults(suiteName: "capture-setting-tests")!
    defaults.removePersistentDomain(forName: "capture-setting-tests")
    var settings = RunnerSettings.load(from: defaults)
    #expect(!settings.captureCertificateEnabled)
    settings.captureCertificateEnabled = true
    settings.save(to: defaults)
    #expect(RunnerSettings.load(from: defaults).captureCertificateEnabled)
}
```

The existing persistence entry point is `RunnerSettings.save(to:)` and it takes
`UserDefaults` with `.standard` as the default; the load side already reads each
key explicitly.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, missing `cacheDirectoryName` and `allowShell`.

- [ ] **Step 3: Implement**

In `KernelSUPatcher`:

```swift
public static func cacheDirectoryName(version: String, kernelHash: String, stockHash: String, allowShell: Bool) -> String {
    let base = "v\(version)-\(kernelHash)-\(stockHash)"
    return allowShell ? base + "-shell" : base
}
```

Change `prepare` to `prepare(imageDirectory: URL, allowShell: Bool, progress: ...)`,
compute `final` with `cacheDirectoryName`, extend `Manifest` with
`let allowShell: Bool`, validate it in `validCache(at:kernelHash:stockHash:allowShell:)`,
and append `--allow-shell` to the `boot-patch` arguments when the flag is true.

In `RunnerSettings` add:

```swift
/// Install a capture proxy's CA into the guest trust store. Enabling this
/// implies shell root on the patched ramdisk, which is why it is separate
/// from `kernelSUEnabled`.
public var captureCertificateEnabled = false
```

Load it with `defaults.bool(forKey: "captureCertificateEnabled")` following the
existing pattern, and include it in the save path.

In `RunnerCoordinator.prepareKernelSU()` pass
`allowShell: RunnerSettings.load().captureCertificateEnabled` into `prepare`.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass. Existing KernelSU tests still pass; the first patched boot after
this change re-prepares because the cache directory name changed for rooted
sessions only.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/KernelSU/KernelSUPatcher.swift MandroidKit/Runner/RunnerSettings.swift MandroidKit/Runner/RunnerCoordinator.swift MandroidKitTests/KernelSUTests.swift
git commit -m "Add optional shell root to KernelSU ramdisk preparation"
```

---

### Task 6: Guest store commands and the KernelSU module injector

**Files:**
- Create: `MandroidKit/Capture/GuestTrustStore.swift`
- Create: `MandroidKit/Capture/CertificateInjecting.swift`
- Create: `MandroidKit/Capture/KernelSUModuleInjector.swift`
- Create: `MandroidKitTests/GuestTrustStoreTests.swift`
- Create: `Scripts/capture-certificate-test.sh`

**Interfaces:**
- Consumes: `ADBClient` (`run`, `shell`), `CaptureCertificate`, `Subprocess`.
- Produces: `CaptureBackend` (`.kernelSUModule`, `.writableSystem`), `CaptureInstallation`, `CertificateInjecting` protocol, `GuestTrustStore` command builders and parsers, `KernelSUModuleInjector`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MandroidKit

@Suite struct GuestTrustStoreTests {
    @Test func serviceScriptCoversBothStorePathsAndEveryNamespace() {
        let script = GuestTrustStore.serviceScript()
        #expect(script.contains("/apex/com.android.conscrypt/cacerts"))
        #expect(script.contains("/system/etc/security/cacerts"))
        #expect(script.contains("nsenter --mount="))
        #expect(script.contains("mount -t tmpfs"))
        #expect(script.contains("plat_file_contexts"))
        #expect(script.contains("*.0"))
    }

    @Test func modulePropertiesCarryTheIdentifier() {
        let properties = GuestTrustStore.moduleProperties()
        #expect(properties.contains("id=reqable-ca") == false)
        #expect(properties.contains("id=capture-ca"))
        #expect(properties.contains("name="))
    }

    @Test func verificationParsesLabelledEntry() {
        let output = "-rw-r--r-- 1 root root u:object_r:system_security_cacerts_file:s0 1818 2026-10-16 17:02 /system/etc/security/cacerts/c76e9e25.0"
        #expect(GuestTrustStore.parseVerification(output, fileName: "c76e9e25.0")
                == .present(label: "u:object_r:system_security_cacerts_file:s0"))
        #expect(GuestTrustStore.parseVerification("", fileName: "c76e9e25.0") == .absent)
        #expect(GuestTrustStore.parseVerification("No such file or directory", fileName: "c76e9e25.0") == .absent)
    }

    @Test func removalTargetsModuleDirectoryAndRunningBinds() {
        let script = GuestTrustStore.removeScript()
        #expect(script.contains(GuestTrustStore.moduleDirectory))
        #expect(script.contains("umount"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `GuestTrustStore` undefined.

- [ ] **Step 3: Implement**

`CertificateInjecting.swift`:

```swift
import Foundation

public enum CaptureBackend: String, Codable, Sendable {
    case kernelSUModule
    case writableSystem
}

public struct CaptureInstallation: Codable, Sendable, Equatable {
    public let fileName: String
    public let subject: String
    public let notAfter: Date
    public let backend: CaptureBackend
    public let installedAt: Date
}

public protocol CertificateInjecting: Sendable {
    func install(_ certificate: CaptureCertificate, adb: ADBClient) async throws -> CaptureInstallation
    func verify(_ installation: CaptureInstallation, adb: ADBClient) async throws -> VerificationState
    func remove(_ installation: CaptureInstallation, adb: ADBClient) async throws
}
```

`GuestTrustStore.swift` holds the validated guest procedure. The service script
below is the version measured working on API 36; keep it verbatim apart from the
module identifier:

```swift
public enum VerificationState: Sendable, Equatable {
    case absent
    case present(label: String)
}

public enum GuestTrustStore {
    public static let moduleDirectory = "/data/adb/modules/capture-ca"
    public static let apexStore = "/apex/com.android.conscrypt/cacerts"
    public static let systemStore = "/system/etc/security/cacerts"

    public static func moduleProperties() -> String {
        """
        id=capture-ca
        name=Capture proxy CA
        version=1.0
        versionCode=1
        author=Mandroid
        description=Adds a debugging proxy CA to the system trust store at boot.
        """
    }

    public static func serviceScript() -> String {
        """
        #!/system/bin/sh
        # Builds a writable copy of the CA store and binds it over the read-only
        # store path in every mount namespace. Runs as root from the module directory.
        MODDIR=${0%/*}
        STORE=/system/etc/security/cacerts
        APEX_STORE=/apex/com.android.conscrypt/cacerts
        CERT=$(ls "$MODDIR"/*.0 2>/dev/null | head -1)
        [ -f "$CERT" ] || exit 1
        [ -d "$APEX_STORE" ] || APEX_STORE="$STORE"

        LABEL=$(grep -h 'security/cacerts' /system/etc/selinux/plat_file_contexts 2>/dev/null | awk '{print $2}' | head -1)
        [ -n "$LABEL" ] || LABEL=u:object_r:system_security_cacerts_file:s0

        mount -t tmpfs tmpfs "$STORE"
        cp "$APEX_STORE"/* "$STORE"/ 2>/dev/null
        cp "$CERT" "$STORE/$(basename "$CERT")"
        chown root:root "$STORE"/* 2>/dev/null
        chmod 644 "$STORE"/* 2>/dev/null
        chmod 755 "$STORE"
        chcon -R "$LABEL" "$STORE" 2>/dev/null

        seen=""
        for pid in $(ls /proc | grep -E '^[0-9]+$'); do
          ns="/proc/$pid/ns/mnt"
          target=$(readlink "$ns" 2>/dev/null) || continue
          case " $seen " in *" $target "*) continue ;; esac
          seen="$seen $target"
          nsenter --mount="$ns" -- /system/bin/mount --bind "$STORE" "$APEX_STORE" 2>/dev/null
        done
        """
    }

    public static func verifyCommand(fileName: String) -> String {
        "ls -lZ /system/etc/security/cacerts/\(fileName)"
    }

    public static func parseVerification(_ output: String, fileName: String) -> VerificationState {
        guard output.contains(fileName), output.contains("root") else { return .absent }
        let fields = output.split(separator: " ").map(String.init)
        guard let label = fields.first(where: { $0.hasPrefix("u:object_r:") }) else { return .present(label: "") }
        return .present(label: label)
    }

    public static func removeScript() -> String {
        """
        MODDIR=\(moduleDirectory)
        umount /system/etc/security/cacerts 2>/dev/null
        umount \(apexStore) 2>/dev/null
        rm -r "$MODDIR"
        """
    }
}
```

`KernelSUModuleInjector.swift`:

```swift
public struct KernelSUModuleInjector: CertificateInjecting {
    public init() {}

    public func install(_ certificate: CaptureCertificate, adb: ADBClient) async throws -> CaptureInstallation {
        let staging = "/data/local/tmp/capture-ca-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(GuestTrustStore.moduleProperties().utf8).write(to: directory.appendingPathComponent("module.prop"))
        let script = directory.appendingPathComponent("service.sh")
        try Data(GuestTrustStore.serviceScript().utf8).write(to: script)
        try await Subprocess.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["755", script.path])
        try Data(certificate.pem.utf8).write(to: directory.appendingPathComponent(certificate.storeFileName))

        _ = try await adb.run(["push", directory.path, staging])
        _ = try await adb.shell("su -c 'mkdir -p \(GuestTrustStore.moduleDirectory) && cp \(staging)/* \(GuestTrustStore.moduleDirectory)/ && chown -R root:root \(GuestTrustStore.moduleDirectory) && chmod 755 \(GuestTrustStore.moduleDirectory)/service.sh && chmod 644 \(GuestTrustStore.moduleDirectory)/module.prop \(GuestTrustStore.moduleDirectory)/\(certificate.storeFileName)'")
        // Apply to the running session so no restart is needed.
        _ = try await adb.shell("su -c 'sh \(GuestTrustStore.moduleDirectory)/service.sh'")
        _ = try await adb.shell("rm -r \(staging)")

        let installation = CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                               notAfter: certificate.notAfter, backend: .kernelSUModule, installedAt: Date())
        let state = try await verify(installation, adb: adb)
        guard case .present(let label) = state, label.hasPrefix("u:object_r:") else {
            throw MandroidKitError.adb("The certificate store entry was not visible after install.")
        }
        return installation
    }

    public func verify(_ installation: CaptureInstallation, adb: ADBClient) async throws -> VerificationState {
        let output = try await adb.shell("su -c '\(GuestTrustStore.verifyCommand(fileName: installation.fileName))'")
        return GuestTrustStore.parseVerification(output, fileName: installation.fileName)
    }

    public func remove(_ installation: CaptureInstallation, adb: ADBClient) async throws {
        _ = try await adb.shell("su -c '\(GuestTrustStore.removeScript())'")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Add the runtime acceptance script**

`Scripts/capture-certificate-test.sh` takes an already booted KernelSU session,
a CA file, and the app's ADB server port; it installs through the injector's
guest commands, checks the entry, reboots, checks again, removes, checks again.
The entry check must also confirm visibility from zygote's mount namespace
(`nsenter --mount=/proc/$(pidof zygote64)/ns/mnt -- ls <store>/<name>`), since
an entry that only exists in the shell's namespace is a silent failure.
Model the environment handling on `Scripts/audit.sh`; use
`ANDROID_SERIAL`, `ADB_SERVER_PORT` and the app's `platform-tools/adb` binary.

Then run it against a live rooted session and paste the output into the task
report.

- [ ] **Step 6: Commit**

```bash
git add MandroidKit/Capture/GuestTrustStore.swift MandroidKit/Capture/CertificateInjecting.swift MandroidKit/Capture/KernelSUModuleInjector.swift MandroidKitTests/GuestTrustStoreTests.swift Scripts/capture-certificate-test.sh
git commit -m "Install capture certificate through a KernelSU module"
```

---

### Task 7: Installation record and controller

**Files:**
- Create: `MandroidKit/Capture/CaptureCertificateStore.swift`
- Create: `MandroidKit/Capture/CaptureCertificateController.swift`
- Create: `MandroidKitTests/CaptureCertificateControllerTests.swift`

**Interfaces:**
- Consumes: `CertificateInjecting`, `CertificateChainChecker`, `CertificateAuthorityResolver`, `CaptureCertificate`, `SDKPaths`.
- Produces: `CaptureCertificateStore` (load/save a `CaptureInstallation?` at `<data root>/capture-certificate.json`), `CaptureCertificateController` with `install(_ certificate: CaptureCertificate, adb: ADBClient)`, `remove(adb:)`, `state`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MandroidKit

private struct FakeInjector: CertificateInjecting {
    var installError: Error?
    var recorded: [CaptureInstallation] = []

    func install(_ certificate: CaptureCertificate, adb: ADBClient) async throws -> CaptureInstallation {
        if let installError { throw installError }
        return CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                   notAfter: certificate.notAfter, backend: .kernelSUModule, installedAt: Date())
    }
    func verify(_ installation: CaptureInstallation, adb: ADBClient) async throws -> VerificationState { .present(label: "u:object_r:system_security_cacerts_file:s0") }
    func remove(_ installation: CaptureInstallation, adb: ADBClient) async throws {}
}

@Suite struct CaptureCertificateControllerTests {
    @Test func installWritesRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CaptureCertificateStore(root: root)
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        #expect(try store.load() == nil)
        let installation = CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                               notAfter: certificate.notAfter, backend: .kernelSUModule, installedAt: Date())
        try store.save(installation)
        #expect(try store.load() == installation)
    }

    @Test func removalClearsRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CaptureCertificateStore(root: root)
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        try store.save(CaptureInstallation(fileName: certificate.storeFileName, subject: certificate.subject,
                                           notAfter: certificate.notAfter, backend: .writableSystem, installedAt: Date()))
        try store.clear()
        #expect(try store.load() == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `CaptureCertificateStore` undefined.

- [ ] **Step 3: Implement both types**

`CaptureCertificateStore` is a thin JSON file wrapper next to the other per-AVD
state:

```swift
public struct CaptureCertificateStore: Sendable {
    private let file: URL
    public init(root: URL) { file = root.appendingPathComponent("capture-certificate.json") }
    public func load() throws -> CaptureInstallation? { /* decode when present */ }
    public func save(_ installation: CaptureInstallation) throws { /* atomic write */ }
    public func clear() throws { /* remove when present */ }
}
```

`CaptureCertificateController` is an actor that sequences pre-flight, install,
verify and record, with both the verdict provider and the injector injected so
tests stay independent of proxies and devices. It exposes two install entry
points: the strict one, which runs the verdict and throws for anything other
than `.trusted`, and an unverified one that skips the verdict for installs the
manual paths make after the user was warned the proxy was not contacted:

```swift
public typealias VerdictProvider = @Sendable (CaptureCertificate) async -> ChainVerdict

public enum CaptureControllerState: Sendable, Equatable {
    case idle
    case installed(CaptureInstallation)
    case unavailable(String)
}

public actor CaptureCertificateController {
    public init(store: CaptureCertificateStore,
                injector: any CertificateInjecting,
                verdict: @escaping VerdictProvider)
    public private(set) var state: CaptureControllerState
    public func install(_ certificate: CaptureCertificate, adb: ADBClient) async throws -> CaptureInstallation
    public func remove(adb: ADBClient) async throws
}
```

Install runs the verdict first; anything other than `.trusted` throws without
touching the guest, with a message that carries the verdict. Append this test to
the same file, and give `FakeInjector` an `installCount` it increments:

```swift
    @Test func foreignIssuerStopsBeforeInstalling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let injector = FakeInjector()
        let controller = CaptureCertificateController(store: CaptureCertificateStore(root: root),
                                                     injector: injector,
                                                     verdict: { _ in .foreignIssuer("Other CA") })
        let certificate = try await CertificateImporter.certificate(fromFile: Fixtures.url("test-ca.pem"))
        await #expect(throws: (any Error).self) {
            _ = try await controller.install(certificate, adb: Self.unusedADB())
        }
        #expect(injector.installCount == 0)
    }
```

Add this helper to the test suite; it builds an `ADBClient` over a temporary
`SDKPaths` and is never used because the verdict short-circuits:

```swift
    static func unusedADB() -> ADBClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ADBClient(paths: SDKPaths(root: root), serverPort: 5137, serial: "emulator-5554")
    }
```

Production builds the probe and checker for the endpoint the user typed and wires `verdict: { certificate in await checker.evaluate(certificate: certificate) }`; the controller itself never sees an endpoint.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/Capture/CaptureCertificateStore.swift MandroidKit/Capture/CaptureCertificateController.swift MandroidKitTests/CaptureCertificateControllerTests.swift
git commit -m "Add capture certificate record and install orchestration"
```

---

### Task 8: Settings section

**Files:**
- Modify: `Mandroid/Settings/SettingsView.swift`
- Modify: `Mandroid/AppDelegate.swift` (only if the controller needs to live on the coordinator)

**Interfaces:**
- Consumes: `CaptureCertificateController`, `CertificateImporter`, `HTTPProxyEndpoint`, `RunnerSettings.captureCertificateEnabled`.
- Produces: the user-visible install/remove flow.

- [ ] **Step 1: Add the section**

Place it directly after the KernelSU section. Contents:

- A note that the feature needs a rooted session and that pinned apps will still
  fail.
- `Toggle("Install a capture proxy certificate", isOn: $settings.captureCertificateEnabled)`.
- `Button("Choose Certificate…")` opening an `NSOpenPanel` for
  `UTType(filenameExtension: "pem")`/`.crt`/`.cer`/`.der`, mirroring `pickAPK()`.
- A paste field plus `Button("Use Pasted Certificate")`.
- `TextField("Proxy host:port", text: $proxyText)` plus
  `Button("Get from Proxy…")`.
- Status line: installed subject and expiry, or the pre-flight verdict.
- File and pasted-PEM installs with no proxy endpoint of their own run the
  pre-flight through the endpoint field when it parses, and otherwise confirm an
  explicit "not verified" alert before installing. Fetching from the proxy stays
  strict: a verdict other than `.trusted` refuses the install.
- `Button("Remove Certificate")`.

Resolving a certificate shows an `NSAlert` with subject and validity before
installing, matching the confirmation style used for uninstall.

- [ ] **Step 2: Verify by hand**

Run the app against a rooted session with Reqable listening, install the CA from
a file, then check the guest:

```bash
adb -s <serial> shell 'su -c "ls -lZ /system/etc/security/cacerts/<hash>.0"'
```

Expected: the entry exists with the platform label; removing it in Settings
removes the entry after the session restarts.

- [ ] **Step 3: Run the unit suite**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Mandroid/Settings/SettingsView.swift Mandroid/AppDelegate.swift
git commit -m "Add capture certificate settings"
```

---

### Task 9: Writable-system launch option and session capabilities

**Files:**
- Modify: `MandroidKit/Emulator/EmulatorLaunchOptions.swift`
- Modify: `MandroidKit/Runner/RunnerSettings.swift`
- Modify: `MandroidKit/Runner/RunnerCoordinator.swift`
- Create: `MandroidKit/Emulator/GuestSessionCapabilities.swift`
- Create: `MandroidKitTests/GuestSessionCapabilitiesTests.swift`

**Interfaces:**
- Consumes: `ADBClient.shell`, `RunnerSettings`, `CaptureCertificateStore`.
- Produces: `EmulatorLaunchOptions.writableSystem`, `RunnerSettings.writableSystemEnabled`, `GuestSessionCapabilities` (`.adbRoot`, `.kernelSUShellRoot`, `.none`) and `GuestSessionCapabilities.detect(adb:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import MandroidKit

@Suite struct GuestSessionCapabilitiesTests {
    @Test func plainShellAsRootMeansAdbRoot() {
        #expect(GuestSessionCapabilities.classify(idOutput: "uid=0(root) gid=0(root) context=u:r:shell:s0", suOutput: nil) == .adbRoot)
    }

    @Test func rootOnlyThroughSuMeansKernelSUShellRoot() {
        let id = "uid=2000(shell) gid=2000(shell) context=u:r:shell:s0"
        let su = "uid=0(root) gid=0(root) context=u:r:ksu:s0"
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: su) == .kernelSUShellRoot)
    }

    @Test func neitherRouteMeansNone() {
        let id = "uid=2000(shell) gid=2000(shell) context=u:r:shell:s0"
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: "su: inaccessible or not found") == .none)
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: nil) == .none)
    }

    @Test func writableSystemAppearsInLaunchArguments() {
        var options = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        options.writableSystem = true
        #expect(options.arguments.contains("-writable-system"))
        options.writableSystem = false
        #expect(!options.arguments.contains("-writable-system"))
    }

    @Test func writableSystemSettingRoundTrips() {
        let defaults = UserDefaults(suiteName: "writable-system-tests")!
        defaults.removePersistentDomain(forName: "writable-system-tests")
        var settings = RunnerSettings.load(from: defaults)
        #expect(!settings.writableSystemEnabled)
        settings.writableSystemEnabled = true
        settings.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults).writableSystemEnabled)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
public enum GuestSessionCapabilities: Sendable, Equatable {
    /// The shell itself is root: a userdebug image with `adb root` accepted.
    case adbRoot
    /// Only `su` reaches root: KernelSU granted the shell access.
    case kernelSUShellRoot
    case none

    public static func classify(idOutput: String, suOutput: String?) -> GuestSessionCapabilities {
        if idOutput.contains("uid=0(") { return .adbRoot }
        if let suOutput, suOutput.contains("uid=0(") { return .kernelSUShellRoot }
        return .none
    }

    public static func detect(adb: ADBClient) async -> GuestSessionCapabilities {
        let idOutput = (try? await adb.shell("id")) ?? ""
        let suOutput = try? await adb.shell("su -c id")
        return classify(idOutput: idOutput, suOutput: suOutput)
    }
}
```

Wire `writableSystem` into `arguments` after the GPU options, add the
`RunnerSettings` flag with the existing persistence pattern, and in
`RunnerCoordinator` after boot: if a `CaptureInstallation` with backend
`.writableSystem` exists and capabilities allow it, re-run the guest store
script (Task 11 provides the injector; call through the same protocol).

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/Emulator/EmulatorLaunchOptions.swift MandroidKit/Emulator/GuestSessionCapabilities.swift MandroidKit/Runner/RunnerSettings.swift MandroidKit/Runner/RunnerCoordinator.swift MandroidKitTests/GuestSessionCapabilitiesTests.swift
git commit -m "Add writable system launch option and session capability probe"
```

---

### Task 10: System image selection and download

**Files:**
- Modify: `MandroidKit/SDK/SDKBootstrap.swift`
- Modify: `MandroidKit/Runner/RunnerSettings.swift`
- Modify: `MandroidKit/Runner/RunnerCoordinator.swift`
- Modify: `Mandroid/Settings/SettingsView.swift`
- Modify: `MandroidKitTests/RepositoryManifestTests.swift` or a new test file

**Interfaces:**
- Consumes: `SDKBootstrap.fetchManifests(tag:)`, `makePlan(tag:)`, `installedSystemImage()`.
- Produces: `SDKBootstrap.installedSystemImages()` (all tags for the highest API level), `RunnerSettings.systemImageTag`, coordinator image choice by tag.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func installedImagesReportEveryTag() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = SDKPaths(root: root)
    for tag in ["google_apis_playstore", "google_apis"] {
        let directory = paths.systemImagesDir.appendingPathComponent("android-33/\(tag)/arm64-v8a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("system.img".utf8).write(to: directory.appendingPathComponent("system.img"))
    }
    let bootstrap = SDKBootstrap(paths: paths)
    let images = bootstrap.installedSystemImages().map(\.packagePath).sorted()
    #expect(images == ["system-images;android-33;google_apis;arm64-v8a",
                       "system-images;android-33;google_apis_playstore;arm64-v8a"])
}

@Test func imageChoicePrefersConfiguredTag() throws {
    // same fixture as above
    #expect(SDKBootstrap.image(matching: "google_apis",
                               among: ["system-images;android-33;google_apis_playstore;arm64-v8a",
                                       "system-images;android-33;google_apis;arm64-v8a"])?.contains(";google_apis;") == true)
}
```

`SDKBootstrap` is an actor constructed as `SDKBootstrap(paths:session:)`; its
existing `installedSystemImage()` is `nonisolated`, so the new lookup is
`nonisolated` too and the test above calls it without `await`. `image(matching:among:)`
is a `static` pure selector.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure.

- [ ] **Step 3: Implement**

Add `installedSystemImages()` beside the existing single-image lookup (do not
change its behaviour for the default tag), plus a pure
`image(matching:among:)` selector. Add `RunnerSettings.systemImageTag`
(persisted key `systemImageTag`, default `SDKBootstrap.defaultTag`) and use it in
`RunnerCoordinator.boot` when writing the AVD config, so choosing
`google_apis` boots that image. Setting the tag to `google_apis` also drives the
download: `Settings ▸ Files` gains the image picker listing installed tags plus a
`Download google_apis Image` action that reports the archive size from the
manifest before starting. Do not enable writable-system automatically; keep the
two toggles independent.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add MandroidKit/SDK/SDKBootstrap.swift MandroidKit/Runner/RunnerSettings.swift MandroidKit/Runner/RunnerCoordinator.swift Mandroid/Settings/SettingsView.swift MandroidKitTests
git commit -m "Add system image tag selection for writable system sessions"
```

---

### Task 11: Writable-system injector

**Files:**
- Create: `MandroidKit/Capture/WritableSystemInjector.swift`
- Create: `MandroidKitTests/WritableSystemInjectorTests.swift`

**Interfaces:**
- Consumes: `GuestTrustStore`, `CaptureCertificate`, `ADBClient`.
- Produces: `WritableSystemInjector` conforming to `CertificateInjecting` with `backend: .writableSystem`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func writableSystemInstallCommandsTargetTheSystemStore() {
    let commands = WritableSystemInjector.installCommands(fileName: "c76e9e25.0",
                                                          staging: "/data/local/tmp/capture-ca-x",
                                                          module: "/data/local/tmp/capture-ca-x")
    #expect(commands.contains { $0.contains("remount") })
    #expect(commands.contains { $0.contains("/system/etc/security/cacerts/c76e9e25.0") })
    #expect(commands.contains { $0.contains("chcon") })
    #expect(commands.contains { $0.contains("sh /data/local/tmp/capture-ca-x/service.sh") })
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure.

- [ ] **Step 3: Implement**

`WritableSystemInjector` pushes the certificate and a copy of the same service
script to a staging directory, then runs: `adb root`, `adb remount`, copy the
entry into the system store with `root:root 0644`, copy the script to a stable
path, and run it with `adb shell sh <path>/service.sh` so the APEX bind applies
to the running session. `verify` reuses `GuestTrustStore.verifyCommand` through
the same shell (no `su -c` prefix; the shell is already root). `remove` deletes
the entry and unmounts the binds. `installCommands(fileName:staging:module:)` is
a static, pure function that returns the command list so the test above can
assert on it without a device.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Run the acceptance script against a userdebug session**

Boot a `google_apis` image with writable system, inject, verify, restart, verify
that the entry persists and the runner re-applies the bind, then remove.

- [ ] **Step 6: Commit**

```bash
git add MandroidKit/Capture/WritableSystemInjector.swift MandroidKitTests/WritableSystemInjectorTests.swift
git commit -m "Add writable system certificate injection"
```

---

### Task 12: Injector selection by session shape

**Files:**
- Create: `MandroidKit/Capture/CertificateInjectorFactory.swift`
- Create: `MandroidKitTests/CertificateInjectorFactoryTests.swift`
- Modify: `Mandroid/Settings/SettingsView.swift`
- Modify: `Scripts/capture-certificate-test.sh`

**Interfaces:**
- Consumes: `GuestSessionCapabilities` (`.adbRoot`, `.kernelSUShellRoot`, `.none`), `CertificateInjecting`, `KernelSUModuleInjector`, `WritableSystemInjector` and its `installCommands(fileName:staging:module:)`, `CaptureCertificateController`.
- Produces: `CertificateInjectorFactory.injector(for:) -> (any CertificateInjecting)?` — `.kernelSUShellRoot` yields the KernelSU injector, `.adbRoot` yields the writable-system injector, `.none` yields nil so the caller can explain why the feature is unavailable; the settings section builds its controller from that choice; the acceptance script gains a mode that renders the writable-system injector's commands.

Without this, nothing in the app can produce a `.writableSystem` record, so that injector and the post-boot re-apply it arms are unreachable.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MandroidKit

@Suite struct CertificateInjectorFactoryTests {
    @Test func kernelSUSessionUsesTheModuleInjector() {
        #expect(CertificateInjectorFactory.injector(for: .kernelSUShellRoot) is KernelSUModuleInjector)
    }

    @Test func writableSystemSessionUsesTheDirectInjector() {
        #expect(CertificateInjectorFactory.injector(for: .adbRoot) is WritableSystemInjector)
    }

    @Test func unprivilegedSessionHasNoInjector() {
        #expect(CertificateInjectorFactory.injector(for: .none) == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: compile failure, `CertificateInjectorFactory` undefined.

- [ ] **Step 3: Implement the factory**

```swift
/// Picks the injector that matches what the running session can actually do.
public enum CertificateInjectorFactory {
    public static func injector(for capabilities: GuestSessionCapabilities) -> (any CertificateInjecting)? {
        switch capabilities {
        case .kernelSUShellRoot: KernelSUModuleInjector()
        case .adbRoot: WritableSystemInjector()
        case .none: nil
        }
    }
}
```

- [ ] **Step 4: Wire the settings section**

Where the section builds its controller, detect the session's capabilities once per action and take the injector from the factory. When the factory returns nil, surface the existing "needs a rooted session" wording instead of attempting an install. Do not change how the controller is otherwise constructed.

- [ ] **Step 5: Add the writable-system mode to the acceptance script**

The script currently renders the KernelSU injector's commands. Give it a mode that renders `WritableSystemInjector`'s command list the same way, with the same kind of drift guard, so the writable-system procedure has an acceptance instrument too. Keep the existing mode's behaviour unchanged and re-check the script with `sh -n`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme Mandroid test 2>&1 | tail -10`
Expected: the three factory tests pass and no existing suite regressed.

- [ ] **Step 7: Commit**

```bash
git add MandroidKit/Capture/CertificateInjectorFactory.swift MandroidKitTests/CertificateInjectorFactoryTests.swift Mandroid/Settings/SettingsView.swift Mandroid.xcodeproj/project.pbxproj Scripts/capture-certificate-test.sh
git commit -m "Choose the certificate injector from the session shape"
```

---

### Task 13: Documentation

**Files:**
- Modify: `docs/KERNELSU.md`
- Modify: `docs/CERTIFICATE-INJECTION.md` (add a short "Using it" section)
- Modify: `README.md`

- [ ] **Step 1: Update `docs/KERNELSU.md`**

State that the capture certificate feature is the one path that grants the ADB
shell root, that it is opt-in and separate from `Boot with KernelSU`, and that
the two patches are cached separately.

- [ ] **Step 2: Add "Using it" to the spec**

Five steps: start the proxy, choose its CA (file, paste, or fetch), confirm the
pre-flight verdict, install, and check status. Add the two caveats exactly as
measurement showed them: Chrome ignores system-store CAs through the Chrome Root
Store, and pinned apps still fail.

- [ ] **Step 3: Mention the feature in `README.md`**

One paragraph beside the per-app proxy paragraph, stating what it does and that
it needs a rooted session.

- [ ] **Step 4: Verify the tree is clean and the suite passes**

```bash
xcodegen generate && git diff --check
xcodebuild -scheme Mandroid build && xcodebuild -scheme Mandroid test
```

- [ ] **Step 5: Commit**

```bash
git add docs/KERNELSU.md docs/CERTIFICATE-INJECTION.md README.md
git commit -m "Document capture certificate injection"
```
