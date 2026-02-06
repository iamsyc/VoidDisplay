import Foundation

enum HttpRoute: Equatable {
    case root
    case stream
    case notFound
}

struct HttpRouter {
    private let streamURL = URL(string: "/stream")!

    func route(for rawPath: String) -> HttpRoute {
        guard let pathURL = URL(string: rawPath) else {
            return .notFound
        }
        if pathURL.isRoot {
            return .root
        }
        if pathURL.hasSubDir(in: streamURL) {
            return .stream
        }
        return .notFound
    }
}
