import Foundation

enum SharePortValidationError: Error, Equatable {
    case empty
    case nonNumeric
    case outOfRange

    var userMessage: String {
        switch self {
        case .empty:
            return String(localized: "Port cannot be empty.")
        case .nonNumeric:
            return String(localized: "Port must be a number.")
        case .outOfRange:
            return String(localized: "Port must be between 1024 and 65535.")
        }
    }

    static func parse(_ rawValue: String) -> Result<UInt16, SharePortValidationError> {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.empty)
        }
        guard let integerValue = Int(trimmed) else {
            return .failure(.nonNumeric)
        }
        guard (1024...65535).contains(integerValue),
              let parsed = UInt16(exactly: integerValue) else {
            return .failure(.outOfRange)
        }
        return .success(parsed)
    }
}

struct WebServiceBinding: Equatable {
    let requestedPort: UInt16
    let boundPort: UInt16
}

enum WebServiceStartFailure: Error, Equatable {
    case invalidPort(SharePortValidationError)
    case portInUse(port: UInt16)
    case permissionDenied(port: UInt16)
    case timedOut(port: UInt16)
    case listenerFailed(port: UInt16, message: String)

    var userMessage: String {
        switch self {
        case .invalidPort(let validationError):
            return validationError.userMessage
        case .portInUse(let port):
            return String(localized: "Port \(port) is already in use. Choose another port and try again.")
        case .permissionDenied(let port):
            return String(localized: "Permission denied for port \(port). Choose another port and try again.")
        case .timedOut(let port):
            return String(localized: "Web service did not become ready on port \(port) in time.")
        case .listenerFailed(_, let message):
            return message
        }
    }
}

enum WebServiceStartResult: Equatable {
    case started(WebServiceBinding)
    case alreadyRunning(WebServiceBinding)
    case failed(WebServiceStartFailure)

    var binding: WebServiceBinding? {
        switch self {
        case .started(let binding), .alreadyRunning(let binding):
            return binding
        case .failed:
            return nil
        }
    }

    var failure: WebServiceStartFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}
