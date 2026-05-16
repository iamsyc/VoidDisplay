@testable import VoidDisplayApp
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplaySharingTestingSupport
import Foundation
import CoreGraphics
import ScreenCaptureKit
import Testing

private actor SharingControllerAsyncGate {
    private var waitCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func currentWaitCount() -> Int {
        waitCount
    }
}

private actor SharingControllerOutcomeBox {
    private var outcome: DisplayStartOutcome<Void>?

    func store(_ outcome: DisplayStartOutcome<Void>) {
        self.outcome = outcome
    }

    func isInvalidated() -> Bool {
        if case .invalidated = outcome {
            return true
        }
        return false
    }
}

@MainActor
struct SharingControllerTests {
    @Test func startWebServiceSyncsState() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let service = MockSharingService()
        service.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        service.activeStreamClientCount = 2
        let displayID: CGDirectDisplayID = 8001
        service.activeSharingDisplayIDs = [displayID]
        service.hasAnyActiveSharing = true

        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(sut.isWebServiceRunning)
        #expect(sut.isSharing)
        #expect(sut.sharingClientCount == 2)
        #expect(sut.activeSharingDisplayIDs.contains(displayID))
    }

    @Test func startWebServicePersistsRequestedPortOnSuccess() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let service = MockSharingService()
        service.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        let preferences = MockSharingPortPreferences()
        let sut = SharingController(
            sharingService: service,
            portPreferences: preferences
        )

        let startResult = await sut.startWebService(requestedPort: requestedPort)

        #expect(startResult == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(preferences.savedPorts == [requestedPort])
        #expect(sut.preferredWebServicePort == requestedPort)
    }

    @Test func stopSharingAndStopAllSharingSyncState() {
        let service = MockSharingService()
        let first: CGDirectDisplayID = 11
        let second: CGDirectDisplayID = 12
        service.isWebServiceRunning = true
        service.activeSharingDisplayIDs = [first, second]
        service.hasAnyActiveSharing = true

        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        sut.stopSharing(displayID: first)
        #expect(!sut.activeSharingDisplayIDs.contains(first))

        sut.stopAllSharing()
        #expect(sut.activeSharingDisplayIDs.isEmpty)
        #expect(!sut.isSharing)
        #expect(service.stopSharingCallCount == 1)
        #expect(service.stopAllSharingCallCount == 1)
    }

    @Test func beginSharingPublishesStartingDisplayIDWhileRequestIsInFlight() async throws {
        let service = MockSharingService()
        let gate = SharingControllerAsyncGate()
        let display = SharedMockSCDisplay.make(displayID: 31, width: 1920, height: 1080)
        service.startSharingHandler = { display in
            await gate.wait()
            return .started(())
        }
        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let task = Task { @MainActor in
            try await sut.beginSharing(display: display)
        }

        #expect(await waitForSharingControllerGate(gate, count: 1))
        #expect(sut.startingDisplayIDs == [display.displayID])
        #expect(sut.isStarting(displayID: display.displayID))

        await gate.releaseOne()
        let outcome = try await task.value

        guard case .started = outcome else {
            Issue.record("Expected sharing start to succeed.")
            return
        }
        #expect(sut.startingDisplayIDs.isEmpty)
        #expect(sut.isStarting(displayID: display.displayID) == false)
    }

    @Test func duplicateBeginSharingCallsShareSameUnderlyingStartOutcome() async throws {
        let gate = SharingControllerAsyncGate()
        let displayID: CGDirectDisplayID = 35
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let subscription = DisplayShareSubscription(
            displayID: displayID,
            shareFrameConsumer: TestSignalSessionHub(),
            cancelClosure: {}
        )
        let sut = makeRealSharingController(
            acquireShare: { _, _ in
                await gate.wait()
                return .started(subscription)
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })

        let firstTask = Task { @MainActor in
            try await sut.beginSharing(display: display)
        }
        #expect(await waitForSharingControllerGate(gate, count: 1))

        let secondTask = Task { @MainActor in
            try await sut.beginSharing(display: display)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedSecondAcquire = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentWaitCount() > 1 {
                observedSecondAcquire = true
                break
            }
            await Task.yield()
        }

        #expect(observedSecondAcquire == false)
        #expect(sut.startingDisplayIDs == [displayID])

        await gate.releaseOne()

        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value
        if case .started = firstOutcome {
        } else {
            Issue.record("Expected first sharing start to succeed.")
        }
        if case .started = secondOutcome {
        } else {
            Issue.record("Expected second sharing start to reuse the in-flight start.")
        }

        #expect(sut.startingDisplayIDs.isEmpty)
        #expect(sut.isSharing(displayID: displayID))
    }

    @Test func beginSharingClearsStartingDisplayIDAfterFailure() async {
        struct ControlledError: Error {}

        let service = MockSharingService()
        let display = SharedMockSCDisplay.make(displayID: 32, width: 1920, height: 1080)
        service.startSharingHandler = { _ in
            throw ControlledError()
        }
        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        do {
            let outcome = try await sut.beginSharing(display: display)
            Issue.record("Expected sharing start to fail, got \(outcome).")
        } catch {
        }

        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @Test func beginSharingClearsStartingDisplayIDAfterInvalidation() async throws {
        let service = MockSharingService()
        let display = SharedMockSCDisplay.make(displayID: 33, width: 1920, height: 1080)
        service.startSharingHandler = { _ in .invalidated }
        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let outcome = try await sut.beginSharing(display: display)

        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }
        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @Test func stopWebServiceClearsStartingDisplayIDImmediatelyAndInvalidatesInFlightStart() async throws {
        let gate = SharingControllerAsyncGate()
        let displayID: CGDirectDisplayID = 37
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let subscription = DisplayShareSubscription(
            displayID: displayID,
            shareFrameConsumer: TestSignalSessionHub(),
            cancelClosure: {}
        )
        let sut = makeRealSharingController(
            acquireShare: { _, _ in
                await gate.wait()
                return .started(subscription)
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })

        let task = Task { @MainActor in
            try await sut.beginSharing(display: display)
        }

        #expect(await waitForSharingControllerGate(gate, count: 1))
        #expect(sut.startingDisplayIDs == [displayID])

        sut.stopWebService()

        #expect(sut.startingDisplayIDs.isEmpty)
        #expect(await waitForSharingControllerTaskInvalidation(task))

        await gate.releaseOne()
        let outcome = try await task.value
        if case .invalidated = outcome {
        } else {
            Issue.record("Expected sharing start to be invalidated after stopping the web service.")
        }
    }

    @Test func sharePageURLResolutionReturnsServiceNotRunningWhenStopped() {
        let service = MockSharingService()
        service.isWebServiceRunning = false
        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let result = sut.sharePageURLResolution(for: nil)

        #expect(result == .failure(.serviceNotRunning))
    }
}

private func waitForSharingControllerGate(
    _ gate: SharingControllerAsyncGate,
    count: Int,
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await gate.currentWaitCount() >= count {
            return true
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return await gate.currentWaitCount() >= count
}

private func waitForSharingControllerTaskInvalidation(
    _ task: Task<DisplayStartOutcome<Void>, Error>,
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000
) async -> Bool {
    let box = SharingControllerOutcomeBox()
    Task {
        guard let outcome = try? await task.value else { return }
        await box.store(outcome)
    }

    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await box.isInvalidated() {
            return true
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return await box.isInvalidated()
}

@MainActor
private func makeRealSharingController(
    acquireShare: DisplaySharingCoordinator.AcquireShare? = nil
) -> SharingController {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
    let coordinator: DisplaySharingCoordinator
    if let acquireShare {
        coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: storeURL),
            acquireShare: acquireShare
        )
    } else {
        coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: storeURL)
        )
    }
    let service = SharingService(
        webServiceController: MockWebServiceController(),
        sharingCoordinator: coordinator
    )
    return SharingController(
        sharingService: service,
        portPreferences: MockSharingPortPreferences()
    )
}

@MainActor
private final class MockSharingPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081
    var savedPorts: [UInt16] = []

    func savePreferredPort(_ port: UInt16) {
        savedPorts.append(port)
        preferredPort = port
    }
}
