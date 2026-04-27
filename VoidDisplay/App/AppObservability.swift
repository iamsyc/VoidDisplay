import Foundation
import OSLog

enum AppLog {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"

    nonisolated static let general = Logger(subsystem: subsystem, category: "general")
    nonisolated static let virtualDisplay = Logger(subsystem: subsystem, category: "virtual_display")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let sharing = Logger(subsystem: subsystem, category: "sharing")
    nonisolated static let web = Logger(subsystem: subsystem, category: "web")
    nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
    nonisolated static let screenCatalog = Logger(subsystem: subsystem, category: "screen_catalog")
    nonisolated static let observability = Logger(subsystem: subsystem, category: "observability")
    nonisolated static let support = Logger(subsystem: subsystem, category: "support")

    nonisolated static func logger(for domain: ObservabilityDomain) -> Logger {
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

enum AppErrorMapper {
    typealias FailureBridge = @Sendable (
        _ error: any Error,
        _ subsystem: ObservabilityDomain,
        _ operation: String,
        _ context: ObservabilityContext
    ) -> Void

    nonisolated(unsafe) private static var failureBridge: FailureBridge?

    static func userMessage(for error: Error, fallback: String) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            return localized
        }
        return fallback
    }

    nonisolated static func logFailure(
        _ operation: String,
        error: Error,
        logger: Logger,
        subsystem: ObservabilityDomain = .general,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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

    nonisolated static func recordIssue(
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

    static func installFailureBridge(_ bridge: @escaping FailureBridge) {
        failureBridge = bridge
    }
}
