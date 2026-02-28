import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct WebServerSocketIntegrationTests {

    @Test func rootRouteSupportsFragmentedSocketRequest() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .unknown },
            liveHubProvider: { _ in nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("VoidDisplay Share"))
    }

    @Test func liveRouteUpgradesToWebSocketWhenTargetActive() async throws {
        let liveHub = LiveSocketHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            liveHubProvider: { target in
                target == .main ? liveHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = websocketUpgradeRequest(path: "/live", port: portValue)
        let responseData = try await Task.detached {
            try sendRequestAndReadPartialResponse(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("101 Switching Protocols"))
        #expect(responseText.contains("Sec-WebSocket-Accept"))
    }

    @Test func legacyStreamRouteReturnsGone() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            liveHubProvider: { _ in LiveSocketHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("410 Gone"))
    }
}
