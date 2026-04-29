import VoidDisplayFoundation
import Foundation
package nonisolated enum ObservabilitySeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    private var sortOrder: Int {
        switch self {
        case .debug:
            0
        case .info:
            1
        case .notice:
            2
        case .warning:
            3
        case .error:
            4
        case .critical:
            5
        }
    }

    package static func < (lhs: ObservabilitySeverity, rhs: ObservabilitySeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
