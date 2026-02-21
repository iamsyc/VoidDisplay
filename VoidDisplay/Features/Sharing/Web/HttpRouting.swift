import Foundation

enum HttpRoute: Equatable {
    case root
    case display(ShareTarget)
    case stream(ShareTarget)
    case notFound
}

enum ShareTarget: Equatable, Hashable, Sendable {
    case main
    case id(UInt32)

    var displayPath: String {
        switch self {
        case .main:
            return "/display"
        case .id(let id):
            return "/display/\(id)"
        }
    }

    var streamPath: String {
        switch self {
        case .main:
            return "/stream"
        case .id(let id):
            return "/stream/\(id)"
        }
    }
}

struct HttpRouter {
    private static let rootPath = "/"
    private static let displayPath = "/display"
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

    private func parseTarget(path: String, prefix: String) -> ShareTarget? {
        if path == prefix {
            return .main
        }

        let marker = "\(prefix)/"
        guard path.hasPrefix(marker) else { return nil }
        let suffix = String(path.dropFirst(marker.count))
        guard !suffix.isEmpty,
              !suffix.contains("/"),
              let parsed = UInt32(suffix),
              parsed > 0 else {
            return nil
        }
        return .id(parsed)
    }

    func route(for rawPath: String) -> HttpRoute {
        guard let path = normalizedPath(from: rawPath) else {
            return .notFound
        }

        if path == Self.rootPath {
            return .root
        }
        if let target = parseTarget(path: path, prefix: Self.displayPath) {
            return .display(target)
        }
        if let target = parseTarget(path: path, prefix: Self.streamPath) {
            return .stream(target)
        }
        return .notFound
    }
}
