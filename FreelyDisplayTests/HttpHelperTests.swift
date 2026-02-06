import Foundation
import Testing
@testable import FreelyDisplay

struct HttpHelperTests {

    @Test func parseHTTPRequestParsesRequestLineAndHeaders() throws {
        let raw = """
        GET /stream HTTP/1.1\r
        Host: 127.0.0.1:8081\r
        X-Test: value\r
        \r
        """

        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))

        #expect(request.method == "GET")
        #expect(request.path == "/stream")
        #expect(request.version == "HTTP/1.1")
        #expect(request.headers["host"] == "127.0.0.1:8081")
        #expect(request.headers["x-test"] == "value")
        #expect(request.body.isEmpty)
    }

    @Test func parseHTTPRequestKeepsBodyWithCRLF() throws {
        let raw = """
        POST /upload HTTP/1.1\r
        Content-Type: text/plain\r
        Content-Length: 12\r
        \r
        hello\r
        world
        """

        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))
        let body = String(data: request.body, encoding: .utf8)

        #expect(request.method == "POST")
        #expect(request.path == "/upload")
        #expect(body == "hello\r\nworld")
    }

    @Test func parseHTTPRequestRejectsInvalidRequestLine() throws {
        let raw = """
        GET_ONLY_TWO_PARTS /stream\r
        Host: localhost\r
        \r
        """
        let data = try #require(raw.data(using: .utf8))
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsNonUTF8Data() {
        let data = Data([0xFF, 0xFE, 0xFD])
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestIgnoresMalformedHeaderLines() throws {
        let raw = """
        GET / HTTP/1.1\r
        Host: localhost\r
        BrokenHeaderLine\r
        \r
        """
        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))

        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["brokenheaderline"] == nil)
    }

    @MainActor @Test func httpRouterRouteDecision() {
        let router = HttpRouter()
        #expect(router.route(for: "/") == .root)
        #expect(router.route(for: "/stream") == .stream)
        #expect(router.route(for: "/stream/") == .stream)
        #expect(router.route(for: "/stream/frame") == .notFound)
        #expect(router.route(for: "/unknown") == .notFound)
        #expect(router.route(for: "%%%") == .notFound)
    }

    @MainActor @Test func webRequestHandlerDecision() {
        let handler = WebRequestHandler()
        #expect(handler.decision(forPath: "/", isSharing: false) == .showDisplayPage)
        #expect(handler.decision(forPath: "/stream", isSharing: true) == .openStream)
        #expect(handler.decision(forPath: "/stream", isSharing: false) == .sharingUnavailable)
        #expect(handler.decision(forPath: "/404", isSharing: true) == .notFound)
    }

    @Test func webRequestHandlerResponsePayloads() throws {
        let handler = WebRequestHandler()
        let page = "<html>ok</html>"

        let rootResponse = handler.responseData(for: .showDisplayPage, displayPage: page)
        let rootText = try #require(String(data: rootResponse, encoding: .utf8))
        #expect(rootText.contains("HTTP/1.1 200 OK"))
        #expect(rootText.contains(page))

        let streamResponse = handler.responseData(for: .openStream, displayPage: page)
        let streamText = try #require(String(data: streamResponse, encoding: .utf8))
        #expect(streamText.contains("multipart/x-mixed-replace"))
        #expect(streamText.contains("boundary=nextFrameK9_4657"))

        let unavailableResponse = handler.responseData(for: .sharingUnavailable, displayPage: page)
        let unavailableText = try #require(String(data: unavailableResponse, encoding: .utf8))
        #expect(unavailableText.contains("503 Service Unavailable"))

        let missingResponse = handler.responseData(for: .notFound, displayPage: page)
        let missingText = try #require(String(data: missingResponse, encoding: .utf8))
        #expect(missingText.contains("404 Not Found"))
    }

    @Test func streamResponseHeaderTerminatesWithCRLFCRLF() throws {
        let handler = WebRequestHandler()
        let response = handler.responseData(for: .openStream, displayPage: "<html></html>")
        let text = try #require(String(data: response, encoding: .utf8))

        #expect(text.hasSuffix("\r\n\r\n"))
        #expect(text.contains("Content-Type: multipart/x-mixed-replace; boundary=\(WebRequestHandler.streamBoundary)"))
    }

    @MainActor @Test func httpRouterTreatsStreamWithQueryAsStreamRoute() {
        let router = HttpRouter()
        #expect(router.route(for: "/stream?t=123") == .stream)
        #expect(router.route(for: "/stream/?t=123") == .stream)
        #expect(router.route(for: "/?v=1") == .root)
    }
}
