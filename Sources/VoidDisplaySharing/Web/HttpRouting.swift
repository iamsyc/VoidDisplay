import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import Security
package enum HttpRoute: Equatable {
    case display(ShareTarget, ShareAccessCapability)
    case signal(ShareTarget, ShareAccessCapability)
    case notFound
}

package struct ShareAccessCapability: Hashable, Sendable {
    package static let pathComponentLength = 64

    package let rawValue: String

    package init?(pathComponent: String) {
        let normalized = pathComponent.lowercased()
        guard normalized.count == Self.pathComponentLength,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            return nil
        }
        rawValue = normalized
    }

    @inline(never)
    package func securelyMatches(_ candidate: ShareAccessCapability) -> Bool {
        let expectedBytes = Array(rawValue.utf8)
        let candidateBytes = Array(candidate.rawValue.utf8)
        guard expectedBytes.count == candidateBytes.count else { return false }
        var difference: UInt8 = 0
        for index in expectedBytes.indices {
            difference |= expectedBytes[index] ^ candidateBytes[index]
        }
        return difference == 0
    }

    package static func generate() throws -> ShareAccessCapability {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ShareAccessCapabilityGenerationError.entropyUnavailable(status)
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        guard let capability = ShareAccessCapability(pathComponent: value) else {
            throw ShareAccessCapabilityGenerationError.invalidGeneratedValue
        }
        return capability
    }
}

package enum ShareAccessCapabilityGenerationError: Error, Equatable {
    case entropyUnavailable(OSStatus)
    case invalidGeneratedValue
}

package enum ShareTarget: Equatable, Hashable, Sendable {
    case main
    case id(UInt32)

    package func displayPath(accessCapability: ShareAccessCapability) -> String {
        switch self {
        case .main:
            return "/display/\(accessCapability.rawValue)"
        case .id(let id):
            return "/display/\(id)/\(accessCapability.rawValue)"
        }
    }

    package func signalPath(accessCapability: ShareAccessCapability) -> String {
        switch self {
        case .main:
            return "/signal/\(accessCapability.rawValue)"
        case .id(let id):
            return "/signal/\(id)/\(accessCapability.rawValue)"
        }
    }
}
package struct HttpRouter {
    private static let displayPath = "/display"
    private static let signalPath = "/signal"

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

    private func parseProtectedTarget(
        path: String,
        prefix: String
    ) -> (target: ShareTarget, capability: ShareAccessCapability)? {
        let marker = "\(prefix)/"
        guard path.hasPrefix(marker) else { return nil }
        let suffix = String(path.dropFirst(marker.count))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 1,
           let capability = ShareAccessCapability(pathComponent: String(components[0])) {
            return (.main, capability)
        }
        guard components.count == 2,
              let parsed = UInt32(components[0]),
              parsed > 0,
              let capability = ShareAccessCapability(pathComponent: String(components[1])) else {
            return nil
        }
        return (.id(parsed), capability)
    }

    package func route(for rawPath: String) -> HttpRoute {
        guard let path = normalizedPath(from: rawPath) else {
            return .notFound
        }

        if let protectedTarget = parseProtectedTarget(path: path, prefix: Self.displayPath) {
            return .display(protectedTarget.target, protectedTarget.capability)
        }
        if let protectedTarget = parseProtectedTarget(path: path, prefix: Self.signalPath) {
            return .signal(protectedTarget.target, protectedTarget.capability)
        }
        return .notFound
    }
}
