import Foundation

nonisolated struct ObservabilitySanitizer: Sendable {
    private let homePath: String
    private let ipv4Pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    private let localURLPattern = #"(https?://)(?:\d{1,3}\.){3}\d{1,3}(:\d+)?"#

    init(homePath: String = NSHomeDirectory()) {
        self.homePath = homePath
    }

    func sanitize(path: String) -> String {
        guard !path.isEmpty else { return path }
        guard !homePath.isEmpty else { return path }
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return redactLocalIPs(in: path)
    }

    func sanitize(fileURL: URL) -> String {
        sanitize(path: fileURL.path)
    }

    func sanitize(text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var sanitized = text
        if !homePath.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homePath + "/", with: "~/")
            if sanitized == homePath {
                sanitized = "~"
            }
        }
        sanitized = redactLocalURLs(in: sanitized)
        sanitized = redactLocalIPs(in: sanitized)
        return sanitized
    }

    func sanitize(metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[entry.key] = sanitize(text: entry.value) ?? entry.value
        }
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
}
