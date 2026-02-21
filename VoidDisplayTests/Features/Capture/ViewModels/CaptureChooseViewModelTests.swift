import CoreGraphics
import Testing
@testable import VoidDisplay

struct CaptureChooseViewModelTests {

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = CaptureChooseViewModel()
        let displayID = CGDirectDisplayID(301)
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
        let sut = CaptureChooseViewModel()
        let firstDisplayID = CGDirectDisplayID(401)
        let secondDisplayID = CGDirectDisplayID(402)
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

    @MainActor @Test func requestPermissionDeniedClearsDisplayState() {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            )
        )
        sut.displays = []
        sut.isLoadingDisplays = true

        sut.requestScreenCapturePermission()

        #expect(sut.hasScreenCapturePermission == false)
        #expect(sut.lastRequestPermission == false)
        #expect(sut.lastPreflightPermission == false)
        #expect(sut.displays == nil)
        #expect(sut.isLoadingDisplays == false)
    }

    @MainActor @Test func refreshPermissionGrantedLoadsDisplaysThroughInjectedLoader() async {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] }
        )

        sut.refreshPermissionAndMaybeLoad()
        let loaded = await waitUntil {
            sut.isLoadingDisplays == false && sut.displays != nil
        }

        #expect(loaded)
        #expect(sut.hasScreenCapturePermission == true)
        #expect(sut.lastPreflightPermission == true)
        #expect(sut.displays?.isEmpty == true)
    }

    @MainActor @Test func loadDisplaysPersistsErrorDetailsWhenLoaderThrows() async {
        let expected = NSError(domain: "CaptureTests", code: 99)
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { throw expected }
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.loadErrorMessage != nil)
        #expect(sut.lastLoadError?.domain == expected.domain)
        #expect(sut.lastLoadError?.code == expected.code)
        #expect(sut.displays == nil)
    }
}
