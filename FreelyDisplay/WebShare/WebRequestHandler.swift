import Foundation

enum WebRequestDecision: Equatable {
    case showDisplayPage
    case openStream
    case sharingUnavailable
    case notFound
}

struct WebRequestHandler {
    private let router = HttpRouter()

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

    func responseData(for decision: WebRequestDecision, displayPage: String) -> Data? {
        switch decision {
        case .showDisplayPage:
            return Data(("HTTP/1.1 200 OK\r\n\r\n" + displayPage).utf8)
        case .sharingUnavailable:
            return Data(
                """
                HTTP/1.1 503 Service Unavailable\r
                Content-Type: text/plain; charset=utf-8\r
                Cache-Control: no-cache\r
                Connection: close\r
                \r
                Sharing has stopped.
                """.utf8
            )
        case .notFound:
            return Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)
        case .openStream:
            return Data(
                """
                HTTP/1.1 200 OK\r
                Content-Type: multipart/x-mixed-replace; boundary=nextFrameK9_4657\r
                Connection: keep-alive\r
                Cache-Control: no-cache\r
                \r
                """.utf8
            )
        }
    }
}
