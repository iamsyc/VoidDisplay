import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilitySectionSanitizer: Sendable {
    private let sanitizer: ObservabilitySanitizer

    package init(sanitizer: ObservabilitySanitizer) {
        self.sanitizer = sanitizer
    }

    package func sanitize(_ sections: [String: JSONValue]) -> [String: JSONValue] {
        sections.mapValues(recursivelySanitize)
    }

    private func recursivelySanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.mapValues(recursivelySanitize))
        case .array(let array):
            return .array(array.map(recursivelySanitize))
        case .string(let string):
            return .string(sanitizer.sanitize(text: string) ?? string)
        case .number, .bool, .null:
            return value
        }
    }

}
