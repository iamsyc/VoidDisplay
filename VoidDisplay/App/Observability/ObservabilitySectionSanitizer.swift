import Foundation

nonisolated struct ObservabilitySectionSanitizer: Sendable {
    private let sanitizer: ObservabilitySanitizer

    init(sanitizer: ObservabilitySanitizer) {
        self.sanitizer = sanitizer
    }

    func sanitize(_ sections: [String: JSONValue]) -> [String: JSONValue] {
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
        let configLabels = makeVirtualDisplayLabels(from: object["configs"])

        if let configs = object["configs"]?.arrayValue {
            object["configs"] = .array(configs.map { configValue in
                guard case .object(var config) = configValue else { return configValue }
                if let id = config["id"]?.stringValue {
                    config["displayName"] = .string(configLabels[id] ?? "Virtual Display")
                }
                return .object(config)
            })
        }

        if let restoreFailures = object["restoreFailures"]?.arrayValue {
            object["restoreFailures"] = .array(restoreFailures.map { failureValue in
                guard case .object(var failure) = failureValue else { return failureValue }
                if let id = failure["configID"]?.stringValue {
                    failure["displayName"] = .string(configLabels[id] ?? "Virtual Display")
                }
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

    private func makeVirtualDisplayLabels(from configsValue: JSONValue?) -> [String: String] {
        let rows: [(id: String, serialNumber: Int)] = configsValue?.arrayValue?.compactMap { configValue in
            guard let object = configValue.objectValue,
                  let id = object["id"]?.stringValue,
                  let serialNumber = object["serialNumber"]?.intValue else {
                return nil
            }
            return (id: id, serialNumber: serialNumber)
        } ?? []

        let sortedRows = rows.sorted { lhs, rhs in
            if lhs.serialNumber == rhs.serialNumber {
                return lhs.id < rhs.id
            }
            return lhs.serialNumber < rhs.serialNumber
        }

        return Dictionary(uniqueKeysWithValues: sortedRows.enumerated().map { index, row in
            (row.id, "Virtual Display \(index + 1)")
        })
    }
}
