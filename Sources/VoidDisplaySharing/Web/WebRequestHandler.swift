import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct AuthorizedShareSession: Sendable {
    package let target: ShareTarget
    package let sessionHub: any SignalSessionHub

    package init(id: UInt32, sessionHub: any SignalSessionHub) {
        target = .id(id)
        self.sessionHub = sessionHub
    }
}

package enum WebRequestDecision {
    case badRequest
    case showDisplayPage(AuthorizedShareSession, ShareAccessCapability)
    case openSignalSocket(AuthorizedShareSession, ShareAccessCapability)
    case methodNotAllowed
    case notFound
}
package struct WebRequestHandler {
    private let router = HttpRouter()

    private func buildResponse(
        statusLine: String,
        headers: [(String, String)] = [],
        body: String = ""
    ) -> Data {
        var response = statusLine + "\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        response += body
        return Data(response.utf8)
    }

    package func decision(
        forMethod method: String,
        path: String,
        authorizationResolver: (ShareTarget, ShareAccessCapability) -> AuthorizedShareSession?
    ) -> WebRequestDecision {
        guard method == "GET" else {
            return .methodNotAllowed
        }
        switch router.route(for: path) {
        case .display(let target, let capability):
            guard let session = authorizationResolver(target, capability) else { return .notFound }
            return .showDisplayPage(session, capability)
        case .signal(let target, let capability):
            guard let session = authorizationResolver(target, capability) else { return .notFound }
            return .openSignalSocket(session, capability)
        case .notFound:
            return .notFound
        }
    }

    package func responseData(
        for decision: WebRequestDecision,
        htmlBody: String = "",
        contentSecurityPolicy: String? = nil
    ) -> Data {
        switch decision {
        case .badRequest:
            let body = "Bad Request"
            return buildResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Length", "\(body.utf8.count)"),
                    ("Connection", "close")
                ],
                body: body
            )
        case .showDisplayPage:
            let resolvedContentSecurityPolicy = contentSecurityPolicy
                ?? "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
            return buildResponse(
                statusLine: "HTTP/1.1 200 OK",
                headers: [
                    ("Content-Type", "text/html; charset=utf-8"),
                    ("Content-Length", "\(htmlBody.utf8.count)"),
                    ("Cache-Control", "no-store"),
                    ("Referrer-Policy", "no-referrer"),
                    ("X-Content-Type-Options", "nosniff"),
                    ("X-Frame-Options", "DENY"),
                    ("Content-Security-Policy", resolvedContentSecurityPolicy)
                ],
                body: htmlBody
            )
        case .methodNotAllowed:
            let body = "Method Not Allowed"
            return buildResponse(
                statusLine: "HTTP/1.1 405 Method Not Allowed",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Length", "\(body.utf8.count)"),
                    ("Allow", "GET"),
                    ("Connection", "close")
                ],
                body: body
            )
        case .notFound:
            let body = "Not Found"
            return buildResponse(
                statusLine: "HTTP/1.1 404 Not Found",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Length", "\(body.utf8.count)"),
                    ("Connection", "close")
                ],
                body: body
            )
        case .openSignalSocket:
            return Data()
        }
    }
}
