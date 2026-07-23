import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit
import CoreGraphics

// Main-actor-owned runtime resources for active preview windows.
// Do not pass across actors/threads.
package struct ScreenPreviewSession: Identifiable {
    package enum State {
        case starting
        case active
    }

    package let id: UUID
    package let displayID: CGDirectDisplayID
    package let displayName: String
    package let resolutionText: String
    package let isVirtualDisplay: Bool
    package let previewSubscription: DisplayPreviewSubscription
    package var capturesCursor: Bool
    package var state: State

    package init(
        id: UUID,
        displayID: CGDirectDisplayID,
        displayName: String,
        resolutionText: String,
        isVirtualDisplay: Bool,
        previewSubscription: DisplayPreviewSubscription,
        capturesCursor: Bool,
        state: State
    ) {
        self.id = id
        self.displayID = displayID
        self.displayName = displayName
        self.resolutionText = resolutionText
        self.isVirtualDisplay = isVirtualDisplay
        self.previewSubscription = previewSubscription
        self.capturesCursor = capturesCursor
        self.state = state
    }
}
