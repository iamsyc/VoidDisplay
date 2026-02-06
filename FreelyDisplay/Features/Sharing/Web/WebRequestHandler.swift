import Foundation

enum WebRequestDecision: Equatable {
    case badRequest
    case showDisplayPage
    case openStream
    case sharingUnavailable
    case methodNotAllowed
    case notFound
}

struct WebRequestHandler {
    private let router = HttpRouter()
    static let streamBoundary = "nextFrameK9_4657"

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

    func decision(
        forMethod method: String,
        path: String,
        isSharing: Bool
    ) -> WebRequestDecision {
        guard method.uppercased() == "GET" else {
            return .methodNotAllowed
        }
        switch router.route(for: path) {
        case .root:
            return .showDisplayPage
        case .stream:
            return isSharing ? .openStream : .sharingUnavailable
        case .notFound:
            return .notFound
        }
    }

    func responseData(for decision: WebRequestDecision, displayPage: String) -> Data {
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
            return buildResponse(
                statusLine: "HTTP/1.1 200 OK",
                headers: [
                    ("Content-Type", "text/html; charset=utf-8"),
                    ("Content-Length", "\(displayPage.utf8.count)"),
                    ("Cache-Control", "no-cache")
                ],
                body: displayPage
            )
        case .sharingUnavailable:
            let body = "Sharing has stopped."
            return buildResponse(
                statusLine: "HTTP/1.1 503 Service Unavailable",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Length", "\(body.utf8.count)"),
                    ("Cache-Control", "no-cache"),
                    ("Connection", "close")
                ],
                body: body
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
        case .openStream:
            return buildResponse(
                statusLine: "HTTP/1.1 200 OK",
                headers: [
                    ("Content-Type", "multipart/x-mixed-replace; boundary=\(Self.streamBoundary)"),
                    ("Cache-Control", "no-cache, no-store, must-revalidate"),
                    ("Pragma", "no-cache"),
                    ("Connection", "keep-alive")
                ]
            )
        }
    }
}
