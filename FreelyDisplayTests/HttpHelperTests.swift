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

    @Test func urlIsRootDetection() throws {
        let root = try #require(URL(string: "/"))
        let stream = try #require(URL(string: "/stream"))

        #expect(root.isRoot)
        #expect(stream.isRoot == false)
    }

    @Test func urlHasSubDirDetection() throws {
        let route = try #require(URL(string: "/stream"))
        let exact = try #require(URL(string: "/stream"))
        let nested = try #require(URL(string: "/stream/frame"))
        let other = try #require(URL(string: "/api"))

        #expect(exact.hasSubDir(in: route))
        #expect(nested.hasSubDir(in: route))
        #expect(other.hasSubDir(in: route) == false)
    }

    @Test func httpRouterRouteDecision() {
        let router = HttpRouter()
        #expect(router.route(for: "/") == .root)
        #expect(router.route(for: "/stream") == .stream)
        #expect(router.route(for: "/stream/frame") == .stream)
        #expect(router.route(for: "/unknown") == .notFound)
        #expect(router.route(for: "%%%") == .notFound)
    }

    @Test func webRequestHandlerDecision() {
        let handler = WebRequestHandler()
        #expect(handler.decision(forPath: "/", isSharing: false) == .showDisplayPage)
        #expect(handler.decision(forPath: "/stream", isSharing: true) == .openStream)
        #expect(handler.decision(forPath: "/stream", isSharing: false) == .sharingUnavailable)
        #expect(handler.decision(forPath: "/404", isSharing: true) == .notFound)
    }

    @Test func webRequestHandlerResponsePayloads() throws {
        let handler = WebRequestHandler()
        let page = "<html>ok</html>"

        let rootResponse = try #require(handler.responseData(for: .showDisplayPage, displayPage: page))
        let rootText = try #require(String(data: rootResponse, encoding: .utf8))
        #expect(rootText.contains("HTTP/1.1 200 OK"))
        #expect(rootText.contains(page))

        let streamResponse = try #require(handler.responseData(for: .openStream, displayPage: page))
        let streamText = try #require(String(data: streamResponse, encoding: .utf8))
        #expect(streamText.contains("multipart/x-mixed-replace"))
        #expect(streamText.contains("boundary=nextFrameK9_4657"))

        let unavailableResponse = try #require(handler.responseData(for: .sharingUnavailable, displayPage: page))
        let unavailableText = try #require(String(data: unavailableResponse, encoding: .utf8))
        #expect(unavailableText.contains("503 Service Unavailable"))

        let missingResponse = try #require(handler.responseData(for: .notFound, displayPage: page))
        let missingText = try #require(String(data: missingResponse, encoding: .utf8))
        #expect(missingText.contains("404 Not Found"))
    }
}
