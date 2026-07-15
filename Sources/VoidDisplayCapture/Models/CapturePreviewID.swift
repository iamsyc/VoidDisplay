import Foundation

package nonisolated struct CapturePreviewID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
