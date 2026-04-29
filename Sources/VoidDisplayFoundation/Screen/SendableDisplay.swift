import CoreGraphics
import ScreenCaptureKit

package nonisolated struct SendableDisplay: @unchecked Sendable {
    package nonisolated(unsafe) let value: SCDisplay
    package nonisolated let displayID: CGDirectDisplayID
    package nonisolated let width: Int
    package nonisolated let height: Int

    package nonisolated init(_ value: SCDisplay) {
        self.value = value
        self.displayID = value.displayID
        self.width = value.width
        self.height = value.height
    }
}
