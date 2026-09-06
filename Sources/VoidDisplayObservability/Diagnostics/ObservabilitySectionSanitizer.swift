import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilitySectionSanitizer: Sendable {
    private let sanitizer: ObservabilitySanitizer

    package init(sanitizer: ObservabilitySanitizer) {
        self.sanitizer = sanitizer
    }

    package func sanitize(_ sections: [String: JSONValue]) -> [String: JSONValue] {
        sections.mapValues(sanitize)
    }

    package func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.reduce(into: [String: JSONValue]()) { result, entry in
                let key = sanitizer.sanitize(text: entry.key) ?? entry.key
                if sanitizer.shouldRedactValue(forKey: entry.key) {
                    result[key] = .string("<redacted>")
                } else {
                    result[key] = sanitize(entry.value)
                }
            })
        case .array(let array):
            return .array(array.map(sanitize))
        case .string(let string):
            return .string(sanitizer.sanitize(text: string) ?? string)
        case .number, .bool, .null:
            return value
        }
    }
}
