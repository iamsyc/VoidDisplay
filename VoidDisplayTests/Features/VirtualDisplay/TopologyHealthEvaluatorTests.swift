import CoreGraphics
import Testing
@testable import VoidDisplay

struct TopologyHealthEvaluatorTests {
    @Test func evaluateDetectsCollapsedMirrorSet() {
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 100,
            displays: [
                makeDisplay(id: 100, serial: 1, managed: true, inMirrorSet: true, mirrorMaster: 10, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                makeDisplay(id: 101, serial: 2, managed: true, inMirrorSet: true, mirrorMaster: 10, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                makeDisplay(id: 10, serial: 999, managed: false, inMirrorSet: true, mirrorMaster: nil, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: [1, 2]
        )

        #expect(evaluation.needsRepair)
        #expect(isCollapsedMirrorIssue(evaluation.issue))
        #expect(evaluation.managedDisplayIDs == [100, 101])
    }

    @Test func evaluateDetectsCollapsedMirrorSetWhenMirrorRootNotFlagged() {
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 100,
            displays: [
                // Mirror root may transiently report not-in-mirror-set.
                makeDisplay(id: 100, serial: 1, managed: true, inMirrorSet: false, mirrorMaster: nil, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                makeDisplay(id: 101, serial: 2, managed: true, inMirrorSet: true, mirrorMaster: 100, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: [1, 2]
        )

        #expect(evaluation.needsRepair)
        #expect(isCollapsedMirrorIssue(evaluation.issue))
        #expect(evaluation.managedDisplayIDs == [100, 101])
    }

    @Test func evaluateDetectsOverlapInExtendedSpace() {
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 100,
            displays: [
                makeDisplay(id: 100, serial: 1, managed: true, inMirrorSet: false, mirrorMaster: nil, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720)),
                makeDisplay(id: 101, serial: 2, managed: true, inMirrorSet: false, mirrorMaster: nil, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720))
            ]
        )

        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: [1, 2]
        )

        #expect(evaluation.needsRepair)
        #expect(isOverlapIssue(evaluation.issue))
    }

    @Test func preferredManagedMainDisplayIDReturnsNilForNonViableMain() {
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 200,
            displays: [
                makeDisplay(id: 200, serial: 1, managed: true, inMirrorSet: false, mirrorMaster: nil, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
            ]
        )

        let preferred = TopologyHealthEvaluator.preferredManagedMainDisplayID(snapshot: snapshot)

        #expect(preferred == nil)
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        serial: UInt32,
        managed: Bool,
        inMirrorSet: Bool,
        mirrorMaster: CGDirectDisplayID?,
        bounds: CGRect
    ) -> DisplayTopologySnapshot.DisplayInfo {
        .init(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isActive: true,
            isInMirrorSet: inMirrorSet,
            mirrorMasterDisplayID: mirrorMaster,
            bounds: bounds
        )
    }

    private func isCollapsedMirrorIssue(_ issue: TopologyHealthEvaluation.Issue?) -> Bool {
        guard let issue else { return false }
        if case .managedDisplaysCollapsedIntoSingleMirrorSet = issue {
            return true
        }
        return false
    }

    private func isOverlapIssue(_ issue: TopologyHealthEvaluation.Issue?) -> Bool {
        guard let issue else { return false }
        if case .managedDisplaysOverlappingInExtendedSpace = issue {
            return true
        }
        return false
    }
}
