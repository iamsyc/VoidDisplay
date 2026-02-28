import Foundation
import Testing
@testable import VoidDisplay

struct WebRoutingWorkflowSmokeTests {

    @MainActor @Test func rootRouteWorkflowSmoke() throws {
        let raw = """
        GET / HTTP/1.1\r
        Host: 127.0.0.1:8081\r
        \r
        """
        let requestData = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: requestData))

        let handler = WebRequestHandler()
        let decision = handler.decision(
            forMethod: request.method,
            path: request.path,
            targetStateProvider: { _ in .unknown }
        )
        #expect(decision == .showRootPage)

        let html = "<html><body>ok</body></html>"
        let response = handler.responseData(for: decision, htmlBody: html)
        let text = try #require(String(data: response, encoding: .utf8))

        #expect(text.contains("HTTP/1.1 200 OK"))
        #expect(text.contains("Content-Type: text/html; charset=utf-8"))
        #expect(text.contains(html))
    }

    @MainActor @Test func liveRouteWorkflowSmoke() throws {
        let raw = """
        GET /live/2 HTTP/1.1\r
        Host: 127.0.0.1:8081\r
        \r
        """
        let requestData = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: requestData))

        let handler = WebRequestHandler()

        let unavailableDecision = handler.decision(
            forMethod: request.method,
            path: request.path,
            targetStateProvider: { _ in .knownInactive }
        )
        #expect(unavailableDecision == .sharingUnavailable)
        let unavailableResponse = handler.responseData(for: unavailableDecision, htmlBody: "")
        let unavailableText = try #require(String(data: unavailableResponse, encoding: .utf8))
        #expect(unavailableText.contains("503 Service Unavailable"))

        let streamDecision = handler.decision(
            forMethod: request.method,
            path: request.path,
            targetStateProvider: { _ in .active }
        )
        #expect(streamDecision == .openLiveSocket(.id(2)))
    }

    @MainActor @Test func legacyStreamRouteReturnsGone() throws {
        let handler = WebRequestHandler()
        let decision = handler.decision(
            forMethod: "GET",
            path: "/stream/2",
            targetStateProvider: { _ in .active }
        )
        #expect(decision == .legacyStreamRemoved)

        let response = handler.responseData(for: decision, htmlBody: "")
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.contains("410 Gone"))
    }
}
