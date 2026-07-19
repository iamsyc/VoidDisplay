@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import VoidDisplaySharingTestingSupport
import Foundation
import Testing

@MainActor
struct HttpHelperTests {

    @Test func parseHTTPRequestParsesRequestLineAndHeaders() throws {
        let raw = "GET /signal HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8081\r\n"
            + "X-Test: value\r\n"
            + "\r\n"

        let data = try #require(raw.data(using: .utf8))
        let request = try #require(parseHTTPRequest(from: data))

        #expect(request.method == "GET")
        #expect(request.path == "/signal")
        #expect(request.headers["host"] == "127.0.0.1:8081")
        #expect(request.headers["x-test"] == "value")
    }

    @Test func parseHTTPRequestIgnoresBytesAfterHeaders() throws {
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
        #expect(request.method == "POST")
        #expect(request.path == "/upload")
        #expect(request.headers["content-length"] == "12")
    }

    @Test func parseHTTPRequestRejectsHeaderWithoutTerminator() throws {
        let raw = "GET /display HTTP/1.1\r\nHost: localhost"
        let data = try #require(raw.data(using: .utf8))

        #expect(parseHTTPRequest(from: data) == nil)
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
        let data = Data([0xFF, 0xFE, 0xFD]) + Data("\r\n\r\n".utf8)
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsMalformedHeaderLines() throws {
        let raw = """
        GET / HTTP/1.1\r
        Host: localhost\r
        BrokenHeaderLine\r
        \r
        """
        let data = try #require(raw.data(using: .utf8))
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsHeaderWithEmptyKey() throws {
        let raw = """
        GET / HTTP/1.1\r
        : value-with-empty-key\r
        Host: localhost\r
        \r
        """
        let data = try #require(raw.data(using: .utf8))
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsInvalidHeaderName() throws {
        let data = try #require(
            "GET / HTTP/1.1\r\nBad Header: value\r\n\r\n".data(using: .utf8)
        )
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsWhitespaceAroundHeaderName() throws {
        let data = try #require(
            "GET / HTTP/1.1\r\n Host : value\r\n\r\n".data(using: .utf8)
        )
        #expect(parseHTTPRequest(from: data) == nil)
    }

    @Test func parseHTTPRequestRejectsUnsupportedHTTPVersion() throws {
        let data = try #require("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".data(using: .utf8))
        #expect(parseHTTPRequest(from: data) == nil)
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
        #expect(router.route(for: "/display//\(capability.rawValue)") == .notFound)
        #expect(router.route(for: "/display/7/\(capability.rawValue)/") == .notFound)
    }

    @MainActor @Test func webRequestHandlerDecision() throws {
        let handler = WebRequestHandler()
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "b", count: 64))
        )
        let mainDisplayPath = ShareTarget.main.displayPath(accessCapability: capability)
        let displayPath = ShareTarget.id(4).displayPath(accessCapability: capability)
        let mainSignalPath = ShareTarget.main.signalPath(accessCapability: capability)
        let hub = TestSignalSessionHub()
        var authorizationCallCount = 0
        let authorizationResolver: (ShareTarget, ShareAccessCapability) -> AuthorizedShareSession? = { target, candidate in
            authorizationCallCount += 1
            guard candidate == capability else { return nil }
            switch target {
            case .main:
                return AuthorizedShareSession(id: 3, sessionHub: hub)
            case .id(let id) where id == 4:
                return AuthorizedShareSession(id: id, sessionHub: hub)
            case .id:
                return nil
            }
        }
        if case .notFound = handler.decision(forMethod: "GET", path: "/", authorizationResolver: authorizationResolver) {} else {
            Issue.record("Expected root route to be rejected.")
        }
        #expect(authorizationCallCount == 0)
        if case .showDisplayPage(let session, let resolvedCapability) = handler.decision(
            forMethod: "GET", path: mainDisplayPath, authorizationResolver: authorizationResolver
        ) {
            #expect(session.target == .id(3))
            #expect(resolvedCapability == capability)
        } else {
            Issue.record("Expected main display route to resolve once.")
        }
        #expect(authorizationCallCount == 1)
        if case .showDisplayPage(let session, _) = handler.decision(
            forMethod: "GET", path: displayPath, authorizationResolver: authorizationResolver
        ) {
            #expect(session.target == .id(4))
        } else {
            Issue.record("Expected concrete display route to resolve.")
        }
        if case .openSignalSocket(let session, let resolvedCapability) = handler.decision(
            forMethod: "GET", path: mainSignalPath, authorizationResolver: authorizationResolver
        ) {
            #expect(session.target == .id(3))
            #expect(ObjectIdentifier(session.sessionHub) == ObjectIdentifier(hub))
            #expect(resolvedCapability == capability)
        } else {
            Issue.record("Expected main signal route to resolve.")
        }
        if case .notFound = handler.decision(
            forMethod: "GET",
            path: ShareTarget.id(9).displayPath(accessCapability: capability),
            authorizationResolver: authorizationResolver
        ) {} else {
            Issue.record("Expected unknown target to be rejected.")
        }
        if case .methodNotAllowed = handler.decision(
            forMethod: "POST", path: mainSignalPath, authorizationResolver: authorizationResolver
        ) {} else {
            Issue.record("Expected non-GET request to be rejected.")
        }
        if case .methodNotAllowed = handler.decision(
            forMethod: "get", path: mainSignalPath, authorizationResolver: authorizationResolver
        ) {} else {
            Issue.record("Expected method matching to remain case-sensitive.")
        }
    }

    @Test func webRequestHandlerResponsePayloads() throws {
        let handler = WebRequestHandler()
        let page = "<html>ok</html>"
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "c", count: 64))
        )
        let session = AuthorizedShareSession(id: 7, sessionHub: TestSignalSessionHub())

        let displayResponse = handler.responseData(
            for: .showDisplayPage(session, capability),
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

    @MainActor @Test func httpRouterRejectsQueryAndPathVariants() throws {
        let router = HttpRouter()
        let capability = try #require(
            ShareAccessCapability(pathComponent: String(repeating: "d", count: 64))
        )
        #expect(router.route(for: "/stream?t=123") == .notFound)
        #expect(router.route(for: "/stream/?t=123") == .notFound)
        #expect(
            router.route(for: "/signal/9/\(capability.rawValue)?t=1") == .notFound
        )
        #expect(
            router.route(for: "/display/9/\(capability.rawValue)?t=1") == .notFound
        )
        #expect(router.route(for: "/display/9/\(capability.rawValue)/") == .notFound)
        #expect(router.route(for: "/display//9/\(capability.rawValue)") == .notFound)
        #expect(router.route(for: "/display/01/\(capability.rawValue)") == .notFound)
        #expect(router.route(for: "/signal/+9/\(capability.rawValue)") == .notFound)
        #expect(router.route(for: "/display/\(capability.rawValue.uppercased())") == .notFound)
        #expect(ShareAccessCapability(pathComponent: capability.rawValue.uppercased()) == nil)
        #expect(router.route(for: "/?v=1") == .notFound)
    }
}
