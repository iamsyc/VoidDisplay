import VoidDisplayFoundation
import Foundation
package nonisolated enum SupportIssueType: String, Codable, CaseIterable, Sendable {
    case blackScreen
    case cannotShare
    case virtualDisplayFailure
    case performanceIssue
    case other
}
