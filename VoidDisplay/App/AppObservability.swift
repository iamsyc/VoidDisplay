import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.0xyuchen.voiddisplay"

    static let virtualDisplay = Logger(subsystem: subsystem, category: "virtual_display")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
    static let web = Logger(subsystem: subsystem, category: "web")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
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

    static func logFailure(
        _ operation: String,
        error: Error,
        logger: Logger
    ) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}
