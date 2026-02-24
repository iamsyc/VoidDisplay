import CoreGraphics
import Testing
@testable import VoidDisplay

struct DisplayTopologyTests {
    @Test func displayInfoIsViableRequiresActiveAndPositiveBounds() {
        let viable = DisplayTopologySnapshot.DisplayInfo(
            id: 1,
            serialNumber: 1,
            isManagedVirtualDisplay: true,
            isActive: true,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let inactive = DisplayTopologySnapshot.DisplayInfo(
            id: 2,
            serialNumber: 2,
            isManagedVirtualDisplay: true,
            isActive: false,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let tiny = DisplayTopologySnapshot.DisplayInfo(
            id: 3,
            serialNumber: 3,
            isManagedVirtualDisplay: true,
            isActive: true,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(viable.isViable)
        #expect(!inactive.isViable)
        #expect(!tiny.isViable)
    }

    @Test func snapshotDisplayLookupReturnsMatchingDisplay() {
        let first = DisplayTopologySnapshot.DisplayInfo(
            id: 10,
            serialNumber: 10,
            isManagedVirtualDisplay: false,
            isActive: true,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
        let second = DisplayTopologySnapshot.DisplayInfo(
            id: 11,
            serialNumber: 11,
            isManagedVirtualDisplay: true,
            isActive: true,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: CGRect(x: 1600, y: 0, width: 1600, height: 900)
        )
        let snapshot = DisplayTopologySnapshot(mainDisplayID: 10, displays: [first, second])

        #expect(snapshot.display(for: 11)?.serialNumber == 11)
        #expect(snapshot.display(for: 999) == nil)
    }
}
