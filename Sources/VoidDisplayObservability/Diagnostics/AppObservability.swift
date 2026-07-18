import VoidDisplayFoundation
import Foundation
import OSLog
package enum AppLog {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"

    package nonisolated static let general = Logger(subsystem: subsystem, category: "general")
    package nonisolated static let virtualDisplay = Logger(subsystem: subsystem, category: "virtual_display")
    package nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    package nonisolated static let sharing = Logger(subsystem: subsystem, category: "sharing")
    package nonisolated static let web = Logger(subsystem: subsystem, category: "web")
    package nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
    package nonisolated static let screenCatalog = Logger(subsystem: subsystem, category: "screen_catalog")
    package nonisolated static let displayRuntime = Logger(subsystem: subsystem, category: "display_runtime")
    package nonisolated static let observability = Logger(subsystem: subsystem, category: "observability")
    package nonisolated static let support = Logger(subsystem: subsystem, category: "support")

    package nonisolated static func logger(for domain: ObservabilityDomain) -> Logger {
        switch domain {
        case .general:
            general
        case .capture:
            capture
        case .sharing:
            sharing
        case .virtualDisplay:
            virtualDisplay
        case .screenCatalog:
            screenCatalog
        case .displayRuntime:
            displayRuntime
        case .persistence:
            persistence
        case .web:
            web
        case .observability:
            observability
        case .support:
            support
        }
    }
}
package enum AppErrorMapper {
    package typealias FailureBridge = @Sendable (
        _ error: any Error,
        _ subsystem: ObservabilityDomain,
        _ operation: String,
        _ context: ObservabilityContext
    ) -> Void

    nonisolated(unsafe) private static var failureBridge: FailureBridge?
    private nonisolated static let sanitizer = ObservabilitySanitizer()

    package static func userMessage(for error: Error, fallback: String) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            return localized
        }
        return fallback
    }

    package nonisolated static func logFailure(
        _ operation: String,
        error: Error,
        logger: Logger,
        subsystem: ObservabilityDomain = .general,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        let safeOperation = sanitizer.sanitize(text: operation) ?? operation
        let rawError = String(describing: error)
        let safeError = sanitizer.sanitize(text: rawError) ?? rawError
        logger.error("\(safeOperation, privacy: .public) failed: \(safeError, privacy: .public)")
        failureBridge?(
            error,
            subsystem,
            operation,
            ObservabilityContext(
                severity: .error,
                metadata: metadata,
                deduplicationKey: deduplicationKey
            )
        )
    }

    package nonisolated static func recordIssue(
        subsystem: ObservabilityDomain,
        operation: String,
        message: String,
        severity: ObservabilitySeverity = .warning,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        failureBridge?(
            NSError(domain: subsystem.rawValue, code: 0, userInfo: [
                NSLocalizedDescriptionKey: message
            ]),
            subsystem,
            operation,
            ObservabilityContext(
                severity: severity,
                metadata: metadata,
                deduplicationKey: deduplicationKey,
                message: message
            )
        )
    }

    package static func installFailureBridge(_ bridge: @escaping FailureBridge) {
        failureBridge = bridge
    }
}
