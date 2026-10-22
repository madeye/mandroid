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

    @Test func presentedChainRejectsHostThatCannotFormAURL() async throws {
        let endpoint = try HTTPProxyEndpoint(host: "127.0.0.1", port: 9001)
        let probe = ProxyProbe(endpoint: endpoint)
        await #expect(throws: MandroidKitError.adb("The proxy host \"bad host\" cannot be used for a TLS handshake.")) {
            _ = try await probe.presentedChain(host: "bad host")
        }
    }
}
