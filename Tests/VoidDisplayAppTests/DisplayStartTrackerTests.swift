@testable import VoidDisplayApp
@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayObservability
@testable import VoidDisplaySupport
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import Testing

@MainActor
struct DisplayStartTrackerTests {
    @Test func beginAndEndTrackSingleDisplayLifecycle() {
        let tracker = DisplayStartTracker()
        let displayID = CGDirectDisplayID(101)

        let token = tracker.begin(displayID: displayID)

        #expect(tracker.contains(displayID: displayID))
        #expect(tracker.activeDisplayIDs == Set([displayID]))

        tracker.end(displayID: displayID, token: token)

        #expect(tracker.contains(displayID: displayID) == false)
        #expect(tracker.activeDisplayIDs.isEmpty)
    }

    @Test func endingOneTokenKeepsDisplayActiveUntilLastTokenLeaves() {
        let tracker = DisplayStartTracker()
        let displayID = CGDirectDisplayID(202)

        let firstToken = tracker.begin(displayID: displayID)
        let secondToken = tracker.begin(displayID: displayID)

        tracker.end(displayID: displayID, token: firstToken)
        #expect(tracker.contains(displayID: displayID))
        #expect(tracker.activeDisplayIDs == Set([displayID]))

        tracker.end(displayID: displayID, token: secondToken)
        #expect(tracker.activeDisplayIDs.isEmpty)
    }

    @Test func clearRemovesOnlySpecifiedDisplay() {
        let tracker = DisplayStartTracker()
        let firstDisplayID = CGDirectDisplayID(303)
        let secondDisplayID = CGDirectDisplayID(304)

        _ = tracker.begin(displayID: firstDisplayID)
        _ = tracker.begin(displayID: secondDisplayID)

        tracker.clear(displayID: firstDisplayID)

        #expect(tracker.contains(displayID: firstDisplayID) == false)
        #expect(tracker.contains(displayID: secondDisplayID))
        #expect(tracker.activeDisplayIDs == Set([secondDisplayID]))
    }

    @Test func clearAllRemovesEveryTrackedDisplay() {
        let tracker = DisplayStartTracker()

        _ = tracker.begin(displayID: CGDirectDisplayID(401))
        _ = tracker.begin(displayID: CGDirectDisplayID(402))

        tracker.clearAll()

        #expect(tracker.activeDisplayIDs.isEmpty)
        #expect(tracker.contains(displayID: CGDirectDisplayID(401)) == false)
        #expect(tracker.contains(displayID: CGDirectDisplayID(402)) == false)
    }
}
