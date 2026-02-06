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

    @Test func parseHTTPRequestPreservesBinaryBodyBytes() throws {
        let header = "POST /upload HTTP/1.1\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: 4\r\n"
            + "\r\n"
        var payload = try #require(header.data(using: .utf8))
        let expectedBody = Data([0x00, 0xFF, 0x10, 0x7F])
        payload.append(expectedBody)

        let request = try #require(parseHTTPRequest(from: payload))
        #expect(request.body == expectedBody)
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
        #expect(handler.decision(forMethod: "GET", path: "/", isSharing: false) == .showDisplayPage)
        #expect(handler.decision(forMethod: "GET", path: "/stream", isSharing: true) == .openStream)
        #expect(handler.decision(forMethod: "GET", path: "/stream", isSharing: false) == .sharingUnavailable)
        #expect(handler.decision(forMethod: "POST", path: "/stream", isSharing: true) == .methodNotAllowed)
        #expect(handler.decision(forMethod: "GET", path: "/404", isSharing: true) == .notFound)
    }

    @Test func webRequestHandlerResponsePayloads() throws {
        let handler = WebRequestHandler()
        let page = "<html>ok</html>"

        let rootResponse = handler.responseData(for: .showDisplayPage, displayPage: page)
        let rootText = try #require(String(data: rootResponse, encoding: .utf8))
        #expect(rootText.contains("HTTP/1.1 200 OK"))
        #expect(rootText.contains(page))

        let badRequestResponse = handler.responseData(for: .badRequest, displayPage: page)
        let badRequestText = try #require(String(data: badRequestResponse, encoding: .utf8))
        let badRequestBody = "Bad Request"
        #expect(badRequestText.contains("400 Bad Request"))
        #expect(badRequestText.contains("Content-Length: \(badRequestBody.utf8.count)"))

        let streamResponse = handler.responseData(for: .openStream, displayPage: page)
        let streamText = try #require(String(data: streamResponse, encoding: .utf8))
        #expect(streamText.contains("multipart/x-mixed-replace"))
        #expect(streamText.contains("boundary=nextFrameK9_4657"))

        let unavailableResponse = handler.responseData(for: .sharingUnavailable, displayPage: page)
        let unavailableText = try #require(String(data: unavailableResponse, encoding: .utf8))
        let unavailableBody = "Sharing has stopped."
        #expect(unavailableText.contains("503 Service Unavailable"))
        #expect(unavailableText.contains("Content-Length: \(unavailableBody.utf8.count)"))

        let methodNotAllowedResponse = handler.responseData(for: .methodNotAllowed, displayPage: page)
        let methodNotAllowedText = try #require(String(data: methodNotAllowedResponse, encoding: .utf8))
        let methodNotAllowedBody = "Method Not Allowed"
        #expect(methodNotAllowedText.contains("405 Method Not Allowed"))
        #expect(methodNotAllowedText.contains("Allow: GET"))
        #expect(methodNotAllowedText.contains("Content-Length: \(methodNotAllowedBody.utf8.count)"))

        let missingResponse = handler.responseData(for: .notFound, displayPage: page)
        let missingText = try #require(String(data: missingResponse, encoding: .utf8))
        let missingBody = "Not Found"
        #expect(missingText.contains("404 Not Found"))
        #expect(missingText.contains("Content-Length: \(missingBody.utf8.count)"))
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
