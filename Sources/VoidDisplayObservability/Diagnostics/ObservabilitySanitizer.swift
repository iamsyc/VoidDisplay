import Darwin
import Foundation
import VoidDisplayFoundation

package nonisolated struct ObservabilitySanitizer: Sendable {
    private let homePath: String
    private let ipv4Pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    private let localURLPattern = #"(https?://)(?:\d{1,3}\.){3}\d{1,3}(:\d+)?"#
    private let ipv6CandidatePattern = #"(?i)(?<![0-9a-f:])\[?[0-9a-f]*:[0-9a-f:]*\]?(?![0-9a-f:])"#
    private let accessTokenPattern = #"(?i)\b[0-9a-f]{64}\b"#
    private let bearerTokenPattern = #"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#
    private let namedSecretPattern = #"(?i)\b(token|secret|password|capability)\s*[:=]\s*([^\s&,;]+)"#
    private let authorizationHeaderPattern = #"(?i)\b(Authorization\s*:\s*)(?:Basic|Bearer)\s+[A-Za-z0-9._~+/=-]{4,}"#
    private let cookieHeaderPattern = #"(?i)\b((?:Set-)?Cookie\s*:\s*)[^\r\n]+"#

    package init(homePath: String = NSHomeDirectory()) {
        self.homePath = homePath
    }

    package func sanitize(path: String) -> String {
        guard !path.isEmpty else { return path }
        var sanitized = path
        if !homePath.isEmpty {
            if sanitized == homePath {
                sanitized = "~"
            } else if sanitized.hasPrefix(homePath + "/") {
                sanitized = "~" + String(sanitized.dropFirst(homePath.count))
            }
        }
        return redactSensitiveText(in: sanitized)
    }

    package func sanitize(fileURL: URL) -> String {
        sanitize(path: fileURL.path)
    }

    package func sanitize(text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var sanitized = text
        if !homePath.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homePath + "/", with: "~/")
            if sanitized == homePath {
                sanitized = "~"
            }
        }
        return redactSensitiveText(in: sanitized)
    }

    package func sanitize(metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[entry.key] = sanitize(value: entry.value, forKey: entry.key)
        }
    }

    package func sanitize(value: String, forKey key: String) -> String {
        guard shouldRedactValue(forKey: key) == false else { return "<redacted>" }
        return sanitize(text: value) ?? value
    }

    package func shouldRedactValue(forKey key: String) -> Bool {
        let normalizedKey = key.lowercased().filter(\.isLetter)
        let sensitiveFragments = [
            "accesstoken",
            "authorization",
            "capability",
            "controltoken",
            "cookie",
            "desktopcontent",
            "displayname",
            "password",
            "secret",
            "shareid",
            "shareurl",
            "usertext",
            "viewerid",
            "windowtitle"
        ]
        return sensitiveFragments.contains { normalizedKey.contains($0) }
    }

    private func redactSensitiveText(in value: String) -> String {
        var redacted = redactLocalURLs(in: value)
        redacted = redactLocalIPs(in: redacted)
        redacted = redactIPv6Addresses(in: redacted)
        redacted = replacingMatches(
            in: redacted,
            pattern: accessTokenPattern,
            template: "<redacted-token>"
        )
        redacted = replacingMatches(
            in: redacted,
            pattern: bearerTokenPattern,
            template: "$1<redacted-token>"
        )
        redacted = replacingMatches(
            in: redacted,
            pattern: namedSecretPattern,
            template: "$1=<redacted-token>"
        )
        redacted = replacingMatches(
            in: redacted,
            pattern: authorizationHeaderPattern,
            template: "$1<redacted-token>"
        )
        redacted = replacingMatches(
            in: redacted,
            pattern: cookieHeaderPattern,
            template: "$1<redacted-token>"
        )
        return truncated(redacted)
    }

    private func truncated(_ value: String) -> String {
        guard value.count > Self.maximumSanitizedTextCharacterCount else { return value }
        let prefixLength = Self.maximumSanitizedTextCharacterCount - Self.truncationMarker.count
        return String(value.prefix(prefixLength)) + Self.truncationMarker
    }

    private func redactLocalIPs(in value: String) -> String {
        replacingMatches(in: value, pattern: ipv4Pattern, template: "<redacted-ip>")
    }

    private func redactLocalURLs(in value: String) -> String {
        replacingMatches(
            in: value,
            pattern: localURLPattern,
            template: "$1<redacted-ip>$2"
        )
    }

    private func redactIPv6Addresses(in value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ipv6CandidatePattern) else {
            return value
        }
        let mutableValue = NSMutableString(string: value)
        let fullRange = NSRange(location: 0, length: mutableValue.length)
        for match in regex.matches(in: value, range: fullRange).reversed() {
            let candidate = mutableValue.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var address = in6_addr()
            guard inet_pton(AF_INET6, candidate, &address) == 1 else { continue }
            mutableValue.replaceCharacters(in: match.range, with: "<redacted-ip>")
        }
        return mutableValue as String
    }

    private func replacingMatches(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static let maximumSanitizedTextCharacterCount = 16_384
    private static let truncationMarker = "…<truncated>"
}
