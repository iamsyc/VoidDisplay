import CoreGraphics
import Foundation

package struct DisplayActivityStatus: Equatable, Sendable {
    package var isPreviewing: Bool
    package var isSharing: Bool

    package init(isPreviewing: Bool, isSharing: Bool) {
        self.isPreviewing = isPreviewing
        self.isSharing = isSharing
    }

    package static let inactive = DisplayActivityStatus(isPreviewing: false, isSharing: false)
}

@MainActor
package protocol DisplayActivityStatusProviding {
    func activityStatus(for displayID: CGDirectDisplayID) -> DisplayActivityStatus
}

package struct StaticDisplayActivityStatusProvider: DisplayActivityStatusProviding {
    private let status: DisplayActivityStatus

    package init(_ status: DisplayActivityStatus) {
        self.status = status
    }

    package func activityStatus(for displayID: CGDirectDisplayID) -> DisplayActivityStatus {
        status
    }
}
