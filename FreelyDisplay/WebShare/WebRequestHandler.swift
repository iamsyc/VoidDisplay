import Foundation

enum WebRequestDecision: Equatable {
    case showDisplayPage
    case openStream
    case sharingUnavailable
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

    func decision(forPath path: String, isSharing: Bool) -> WebRequestDecision {
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
            return buildResponse(
                statusLine: "HTTP/1.1 503 Service Unavailable",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Cache-Control", "no-cache"),
                    ("Connection", "close")
                ],
                body: "Sharing has stopped."
            )
        case .notFound:
            return buildResponse(
                statusLine: "HTTP/1.1 404 Not Found",
                headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Connection", "close")
                ],
                body: "Not Found"
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
