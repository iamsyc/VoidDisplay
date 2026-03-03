import Foundation
import OSLog

enum AppLog {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"

    nonisolated static let virtualDisplay = Logger(subsystem: subsystem, category: "virtual_display")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let sharing = Logger(subsystem: subsystem, category: "sharing")
    nonisolated static let web = Logger(subsystem: subsystem, category: "web")
    nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

enum AppErrorMapper {
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
        logger: Logger
    ) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}
