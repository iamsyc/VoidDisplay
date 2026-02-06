import Foundation

enum HttpRoute: Equatable {
    case root
    case stream
    case notFound
}

struct HttpRouter {
    private static let rootPath = "/"
    private static let streamPath = "/stream"

    private func normalizedPath(from rawPath: String) -> String? {
        guard !rawPath.isEmpty else { return nil }
        guard let path = URLComponents(string: rawPath)?.path, !path.isEmpty else {
            return nil
        }
        guard path.hasPrefix("/") else { return nil }

        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    func route(for rawPath: String) -> HttpRoute {
        guard let path = normalizedPath(from: rawPath) else {
            return .notFound
        }

        if path == Self.rootPath {
            return .root
        }
        if path == Self.streamPath {
            return .stream
        }
        return .notFound
    }
}
