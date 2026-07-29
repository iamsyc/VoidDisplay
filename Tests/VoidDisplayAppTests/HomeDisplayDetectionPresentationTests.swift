@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import Testing

@Suite
struct HomeDisplayDetectionPresentationTests {
    @Test func reportsUpdatedDisplayCountWhenCatalogChanges() {
        let previous = catalog(displayIDs: [1001])
        let current = catalog(displayIDs: [1001, 1002])

        let presentation = HomeDisplayDetectionPresentation.completion(
            previousCatalog: previous,
            currentCatalog: current
        )

        #expect(presentation == .updated(displayCount: 2))
        #expect(presentation.isTransient)
    }

    @Test func reportsUpToDateWhenCatalogIsUnchanged() {
        let snapshot = catalog(displayIDs: [1001])

        let presentation = HomeDisplayDetectionPresentation.completion(
            previousCatalog: snapshot,
            currentCatalog: snapshot
        )

        #expect(presentation == .upToDate(displayCount: 1))
        #expect(presentation.isTransient)
    }

    @Test func reportsPermissionRequirementBeforeLoadFailure() {
        let presentation = HomeDisplayDetectionPresentation.completion(
            previousCatalog: catalog(displayIDs: [1001]),
            currentCatalog: catalog(
                permissionGranted: false,
                hasLoadError: true,
                displayIDs: []
            )
        )

        #expect(presentation == .permissionRequired)
        #expect(!presentation.showsStatus)
    }

    @Test func reportsRecoverableFailureWhenCatalogLoadFails() {
        let presentation = HomeDisplayDetectionPresentation.completion(
            previousCatalog: catalog(displayIDs: [1001]),
            currentCatalog: catalog(hasLoadError: true, displayIDs: [1001])
        )

        #expect(presentation == .failed)
        #expect(presentation.showsStatus)
        #expect(presentation.showsRetryAction)
    }

    @Test func keepsToolbarTitleStableWhileReportingScanningAccessibilityValue() {
        let idle = HomeDisplayDetectionPresentation.idle
        let scanning = HomeDisplayDetectionPresentation.scanning

        #expect(scanning.toolbarTitle == idle.toolbarTitle)
        #expect(idle.toolbarAccessibilityValue.isEmpty)
        #expect(!scanning.toolbarAccessibilityValue.isEmpty)
    }

    private func catalog(
        permissionGranted: Bool? = true,
        hasLoadError: Bool = false,
        displayIDs: [DisplayRuntimeDisplayID]
    ) -> DisplayRuntimeCatalogSnapshot {
        DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: permissionGranted,
            lastPreflightPermission: permissionGranted,
            lastRequestPermission: nil,
            isLoadingDisplays: false,
            hasLoadError: hasLoadError,
            lastLoadError: nil,
            loadedDisplays: displayIDs.map {
                DisplayRuntimeCatalogDisplay(
                    displayID: $0,
                    pixelWidth: 1920,
                    pixelHeight: 1080
                )
            },
            topologySignature: []
        )
    }
}
