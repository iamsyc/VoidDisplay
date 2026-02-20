import CoreGraphics
import Testing
@testable import FreelyDisplay

struct ShareViewModelTests {

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = ShareViewModel()
        let displayID = CGDirectDisplayID(101)
        var enteredCount = 0
        var firstDidEnter = false
        var allowFirstToFinish = false

        let firstTask = Task { @MainActor in
            await sut.withDisplayStartLock(displayID: displayID) {
                enteredCount += 1
                firstDidEnter = true
                while !allowFirstToFinish {
                    await Task.yield()
                }
            }
        }

        while !firstDidEnter {
            await Task.yield()
        }

        let secondStarted = await sut.withDisplayStartLock(displayID: displayID) {
            enteredCount += 1
        }

        allowFirstToFinish = true
        let firstStarted = await firstTask.value

        #expect(firstStarted)
        #expect(secondStarted == false)
        #expect(enteredCount == 1)
        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @MainActor @Test func withDisplayStartLockAllowsConcurrentStartForDifferentDisplays() async {
        let sut = ShareViewModel()
        let firstDisplayID = CGDirectDisplayID(201)
        let secondDisplayID = CGDirectDisplayID(202)
        var enteredDisplayIDs: Set<CGDirectDisplayID> = []
        var firstDidEnter = false
        var allowFirstToFinish = false

        let firstTask = Task { @MainActor in
            await sut.withDisplayStartLock(displayID: firstDisplayID) {
                enteredDisplayIDs.insert(firstDisplayID)
                firstDidEnter = true
                while !allowFirstToFinish {
                    await Task.yield()
                }
            }
        }

        while !firstDidEnter {
            await Task.yield()
        }

        let secondStarted = await sut.withDisplayStartLock(displayID: secondDisplayID) {
            enteredDisplayIDs.insert(secondDisplayID)
        }

        allowFirstToFinish = true
        let firstStarted = await firstTask.value

        #expect(firstStarted)
        #expect(secondStarted)
        #expect(enteredDisplayIDs == [firstDisplayID, secondDisplayID])
        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @MainActor @Test func requestPermissionDeniedClearsDisplaysAndSetsErrorMessage() {
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            )
        )
        let appHelper = makeAppHelper()
        sut.displays = []
        sut.isLoadingDisplays = true

        sut.requestScreenCapturePermission(appHelper: appHelper)

        #expect(sut.hasScreenCapturePermission == false)
        #expect(sut.lastRequestPermission == false)
        #expect(sut.lastPreflightPermission == false)
        #expect(sut.displays == nil)
        #expect(sut.isLoadingDisplays == false)
        #expect(sut.loadErrorMessage != nil)
    }

    @MainActor @Test func loadDisplaysRegistersDisplaysThroughAppHelper() async {
        let sharing = MockSharingService()
        let appHelper = makeAppHelper(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] }
        )

        sut.loadDisplays(appHelper: appHelper)
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.displays != nil
        }

        #expect(finished)
        #expect(sut.displays?.isEmpty == true)
        #expect(sharing.registerShareableDisplaysCallCount == 1)
    }

    @MainActor @Test func loadDisplaysRecordsDetailedErrorWhenLoaderFails() async {
        let appHelper = makeAppHelper()
        let expected = NSError(domain: "ShareTests", code: 77)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { throw expected }
        )

        sut.loadDisplays(appHelper: appHelper)
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.loadErrorMessage != nil)
        #expect(sut.lastLoadError?.domain == expected.domain)
        #expect(sut.lastLoadError?.code == expected.code)
    }

    @MainActor @Test func startServiceFailurePresentsUserFacingError() async {
        let sharing = MockSharingService()
        sharing.startResult = false
        let appHelper = makeAppHelper(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            )
        )

        sut.startService(appHelper: appHelper)
        let presented = await waitUntil {
            sut.showOpenPageError
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 1)
        #expect(sut.openPageErrorMessage.isEmpty == false)
    }

    @MainActor
    private func makeAppHelper() -> AppHelper {
        makeAppHelper(sharing: MockSharingService())
    }

    @MainActor
    private func makeAppHelper(sharing: MockSharingService) -> AppHelper {
        AppHelper(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: sharing,
            virtualDisplayService: MockVirtualDisplayService(),
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: false
        )
    }
}
