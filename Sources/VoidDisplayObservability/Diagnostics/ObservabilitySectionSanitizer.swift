import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilitySectionSanitizer: Sendable {
    private let sanitizer: ObservabilitySanitizer

    package init(sanitizer: ObservabilitySanitizer) {
        self.sanitizer = sanitizer
    }

    package func sanitize(_ sections: [String: JSONValue]) -> [String: JSONValue] {
        var sanitizedSections = sections.mapValues(recursivelySanitize)

        if let capture = sanitizedSections["capture"] {
            sanitizedSections["capture"] = sanitizeCapture(capture)
        }

        if let virtualDisplay = sanitizedSections["virtualDisplay"] {
            sanitizedSections["virtualDisplay"] = sanitizeVirtualDisplay(virtualDisplay)
        }

        return sanitizedSections
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

    private func sanitizeCapture(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let displayLabels = makeDisplayLabels(from: object["sessions"])

        if let sessions = object["sessions"]?.arrayValue {
            object["sessions"] = .array(sessions.map { sessionValue in
                guard case .object(var session) = sessionValue else { return sessionValue }
                if let displayID = session["displayID"]?.uint32Value {
                    session["displayName"] = .string(displayLabels[displayID] ?? "Display")
                }
                return .object(session)
            })
        }

        return .object(object)
    }

    private func sanitizeVirtualDisplay(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return value }

        if let configs = object["configs"]?.arrayValue {
            object["configs"] = .array(configs.map { configValue in
                guard case .object(var config) = configValue else { return configValue }
                config.removeValue(forKey: "displayName")
                return .object(config)
            })
        }

        if let restoreFailures = object["restoreFailures"]?.arrayValue {
            object["restoreFailures"] = .array(restoreFailures.map { failureValue in
                guard case .object(var failure) = failureValue else { return failureValue }
                failure.removeValue(forKey: "displayName")
                return .object(failure)
            })
        }

        return .object(object)
    }

    private func makeDisplayLabels(from sessionsValue: JSONValue?) -> [UInt32: String] {
        let ids = Set(
            sessionsValue?.arrayValue?.compactMap { sessionValue in
                sessionValue.objectValue?["displayID"]?.uint32Value
            } ?? []
        ).sorted()

        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, "Display \(index + 1)")
        })
    }

}
