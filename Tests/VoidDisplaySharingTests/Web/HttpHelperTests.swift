@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import Foundation
import Testing

@MainActor
struct HttpHelperTests {

    @Test func parseHTTPRequestParsesRequestLineAndHeaders() throws {
        let raw = """
        GET /signal HTTP/1.1\r
        Host: 127.0.0.1:8081\r
        X-Test: value\r
        \r
        """

        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))

        #expect(request.method == "GET")
        #expect(request.path == "/signal")
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

    @Test func parseHTTPRequestAllowsHeaderOnlyPayloadWithoutTerminator() throws {
        let raw = "GET /display HTTP/1.1\r\nHost: localhost"
        let data = try #require(raw.data(using: .utf8))

        let request = try #require(parseHTTPRequest(from: data))
        #expect(request.method == "GET")
        #expect(request.path == "/display")
        #expect(request.headers["host"] == "localhost")
        #expect(request.body.isEmpty)
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
        GET_ONLY_TWO_PARTS /signal\r
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

    @Test func parseHTTPRequestIgnoresHeaderWithEmptyKey() throws {
        let raw = """
        GET / HTTP/1.1\r
        : value-with-empty-key\r
        Host: localhost\r
        \r
        """
        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))

        #expect(request.headers[""] == nil)
        #expect(request.headers["host"] == "localhost")
    }

    @MainActor @Test func httpRouterRouteDecision() throws {
        let router = HttpRouter()
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "a", count: 64))
        )
        #expect(router.route(for: "/") == .notFound)
        #expect(router.route(for: "/display") == .notFound)
        #expect(router.route(for: "/display/7") == .notFound)
        #expect(router.route(for: "/display/\(capability.rawValue)") == .display(.main, capability))
        #expect(router.route(for: "/display/7/\(capability.rawValue)") == .display(.id(7), capability))
        #expect(router.route(for: "/stream") == .notFound)
        #expect(router.route(for: "/stream/7") == .notFound)
        #expect(router.route(for: "/stream/") == .notFound)
        #expect(router.route(for: "/signal/7") == .notFound)
        #expect(router.route(for: "/signal/7/\(capability.rawValue)") == .signal(.id(7), capability))
        #expect(router.route(for: "/stream/frame") == .notFound)
        #expect(router.route(for: "/display/frame") == .notFound)
        #expect(router.route(for: "/unknown") == .notFound)
        #expect(router.route(for: "%%%") == .notFound)
    }

    @MainActor @Test func webRequestHandlerDecision() throws {
        let handler = WebRequestHandler()
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "b", count: 64))
        )
        let mainDisplayPath = ShareTarget.main.displayPath(accessCapability: capability)
        let displayPath = ShareTarget.id(4).displayPath(accessCapability: capability)
        let mainSignalPath = ShareTarget.main.signalPath(accessCapability: capability)
        let acceptsCapability: (ShareTarget, ShareAccessCapability) -> Bool = { _, candidate in
            candidate == capability
        }
        #expect(
            handler.decision(
                forMethod: "GET",
                path: "/",
                targetStateProvider: { _ in .knownInactive },
                accessValidator: acceptsCapability
            ) == .notFound
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: mainDisplayPath,
                targetStateProvider: { _ in .knownInactive },
                accessValidator: acceptsCapability
            ) == .showDisplayPage(.main, capability)
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: displayPath,
                targetStateProvider: { _ in .active },
                accessValidator: acceptsCapability
            ) == .showDisplayPage(.id(4), capability)
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: mainSignalPath,
                targetStateProvider: { _ in .active },
                accessValidator: acceptsCapability
            ) == .openSignalSocket(.main, capability)
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: displayPath,
                targetStateProvider: { _ in .active },
                accessValidator: { _, _ in false }
            ) == .notFound
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: "/stream",
                targetStateProvider: { _ in .active },
                accessValidator: acceptsCapability
            ) == .notFound
        )
        #expect(
            handler.decision(
                forMethod: "POST",
                path: mainSignalPath,
                targetStateProvider: { _ in .active },
                accessValidator: acceptsCapability
            ) == .methodNotAllowed
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: "/404",
                targetStateProvider: { _ in .active },
                accessValidator: acceptsCapability
            ) == .notFound
        )
        #expect(
            handler.decision(
                forMethod: "GET",
                path: ShareTarget.id(9).displayPath(accessCapability: capability),
                targetStateProvider: { _ in .unknown },
                accessValidator: acceptsCapability
            ) == .notFound
        )
    }

    @Test func webRequestHandlerResponsePayloads() throws {
        let handler = WebRequestHandler()
        let page = "<html>ok</html>"
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "c", count: 64))
        )

        let displayResponse = handler.responseData(
            for: .showDisplayPage(.id(7), capability),
            htmlBody: page,
            contentSecurityPolicy: "default-src 'none'; script-src 'nonce-testnonce'"
        )
        let displayText = try #require(String(data: displayResponse, encoding: .utf8))
        #expect(displayText.contains("HTTP/1.1 200 OK"))
        #expect(displayText.contains(page))
        #expect(displayText.contains("Cache-Control: no-store"))
        #expect(displayText.contains("Referrer-Policy: no-referrer"))
        #expect(displayText.contains("X-Frame-Options: DENY"))
        #expect(displayText.contains("Content-Security-Policy: default-src 'none'; script-src 'nonce-testnonce'"))

        let badRequestResponse = handler.responseData(for: .badRequest, htmlBody: page)
        let badRequestText = try #require(String(data: badRequestResponse, encoding: .utf8))
        let badRequestBody = "Bad Request"
        #expect(badRequestText.contains("400 Bad Request"))
        #expect(badRequestText.contains("Content-Length: \(badRequestBody.utf8.count)"))

        let unavailableResponse = handler.responseData(for: .sharingUnavailable, htmlBody: page)
        let unavailableText = try #require(String(data: unavailableResponse, encoding: .utf8))
        let unavailableBody = "Sharing has stopped."
        #expect(unavailableText.contains("503 Service Unavailable"))
        #expect(unavailableText.contains("Content-Length: \(unavailableBody.utf8.count)"))

        let methodNotAllowedResponse = handler.responseData(for: .methodNotAllowed, htmlBody: page)
        let methodNotAllowedText = try #require(String(data: methodNotAllowedResponse, encoding: .utf8))
        let methodNotAllowedBody = "Method Not Allowed"
        #expect(methodNotAllowedText.contains("405 Method Not Allowed"))
        #expect(methodNotAllowedText.contains("Allow: GET"))
        #expect(methodNotAllowedText.contains("Content-Length: \(methodNotAllowedBody.utf8.count)"))

        let missingResponse = handler.responseData(for: .notFound, htmlBody: page)
        let missingText = try #require(String(data: missingResponse, encoding: .utf8))
        let missingBody = "Not Found"
        #expect(missingText.contains("404 Not Found"))
        #expect(missingText.contains("Content-Length: \(missingBody.utf8.count)"))
    }

    @Test func notFoundResponseHeaderTerminatesWithCRLFCRLF() throws {
        let handler = WebRequestHandler()
        let response = handler.responseData(for: .notFound, htmlBody: "<html></html>")
        let text = try #require(String(data: response, encoding: .utf8))
        let components = text.components(separatedBy: "\r\n\r\n")

        #expect(components.count == 2)
        #expect(components[0].contains("HTTP/1.1 404 Not Found"))
        #expect(components[1] == "Not Found")
        #expect(text.contains("404 Not Found"))
    }

    @MainActor @Test func httpRouterTreatsQueryRoutesConsistently() throws {
        let router = HttpRouter()
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "d", count: 64))
        )
        #expect(router.route(for: "/stream?t=123") == .notFound)
        #expect(router.route(for: "/stream/?t=123") == .notFound)
        #expect(
            router.route(for: "/signal/9/\(capability.rawValue)?t=1") == .signal(.id(9), capability)
        )
        #expect(
            router.route(for: "/display/9/\(capability.rawValue)?t=1") == .display(.id(9), capability)
        )
        #expect(router.route(for: "/?v=1") == .notFound)
    }
}
