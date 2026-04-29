@testable import VoidDisplayFoundation
import CoreGraphics

@MainActor
package func makeTestDisplayTopologySignature(
    _ displayIDs: [CGDirectDisplayID]
) -> ScreenCaptureDisplayTopologySignature {
    displayIDs.map { ScreenCaptureDisplayTopologySignatureEntry(displayID: $0) }
}

@MainActor
package func makeTestDisplayTopologySignatureEntry(
    displayID: CGDirectDisplayID,
    isMain: Bool = false,
    pixelWidth: Int = 0,
    pixelHeight: Int = 0,
    refreshRateMilliHertz: Int? = nil,
    mirrorsDisplayID: CGDirectDisplayID? = nil
) -> ScreenCaptureDisplayTopologySignatureEntry {
    .init(
        displayID: displayID,
        isMain: isMain,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        refreshRateMilliHertz: refreshRateMilliHertz,
        mirrorsDisplayID: mirrorsDisplayID
    )
}

package struct MockScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    package let preflightResult: Bool
    package let requestResult: Bool

    package nonisolated init(preflightResult: Bool, requestResult: Bool) {
        self.preflightResult = preflightResult
        self.requestResult = requestResult
    }

    package nonisolated func preflight() -> Bool {
        preflightResult
    }

    package nonisolated func request() -> Bool {
        requestResult
    }
}
