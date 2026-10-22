import Foundation
import Security

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
        guard let url = URL(string: "https://\(host)/") else {
            throw MandroidKitError.adb("The proxy host \"\(host)\" cannot be used for a TLS handshake.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        let chain = capture.certificates
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
