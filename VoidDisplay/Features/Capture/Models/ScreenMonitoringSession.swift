import Foundation
import ScreenCaptureKit
import CoreGraphics

// Main-actor-owned runtime resources for active monitoring windows.
// Do not pass across actors/threads.
struct ScreenMonitoringSession: Identifiable {
    enum State {
        case starting
        case active
    }

    let id: UUID
    let displayID: CGDirectDisplayID
    let displayName: String
    let resolutionText: String
    let isVirtualDisplay: Bool
    let stream: SCStream
    let delegate: StreamDelegate
    var state: State
}
