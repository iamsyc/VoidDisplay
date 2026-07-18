@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharingTestingSupport
@testable import VoidDisplayTestingSupport
import Foundation
import CoreGraphics
import ScreenCaptureKit
import Testing

private final class SharingServiceCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0

    nonisolated func increment() {
        value += 1
    }
}

private actor SharingServiceAsyncGate {
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

private actor SharingServiceOutcomeBox {
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

private func sharingEvent(
    target: ShareTarget,
    clientID: String = "client-1",
    sessionEpoch: UInt64 = 0,
    sequence: UInt64 = 1,
    phase: SharingPeerPhase,
    source: SharingSessionEventSource
) -> SharingSessionEvent {
    SharingSessionEvent(
        target: target,
        clientID: clientID,
        sessionEpoch: sessionEpoch,
        sequence: sequence,
        phase: phase,
        source: source
    )
}

struct SharingServiceTests {

    @MainActor @Test func startWebServiceDelegatesToControllerAndCapturesProviders() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .started(
            WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        )
        let sut = makeService(webServiceController: mock)

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(mock.startCallCount == 1)
        #expect(sut.webServicePortValue == requestedPort)
        #expect(sut.isWebServiceRunning)
        #expect(mock.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(mock.capturedTargetStateProvider?(.id(123)) == .unknown)
        #expect(mock.capturedConcreteTargetResolver?(.main) == nil)
        #expect(mock.capturedConcreteTargetResolver?(.id(123)) == nil)
        #expect(mock.capturedSessionHubProvider?(.main) == nil)
        #expect(mock.capturedSharingEventSink != nil)
    }

    @MainActor @Test func startWebServiceReturnsFalseWhenControllerFails() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .failed(.portInUse(port: requestedPort))
        let sut = makeService(webServiceController: mock)

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .failed(.portInUse(port: requestedPort)))
        #expect(mock.startCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func stopSingleSharingDisconnectsOnlyTheResolvedTarget() throws {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
		let displayID = CGDirectDisplayID(11)
		let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
		sut.registerShareableDisplays([display], virtualSerialResolver: { _ in 77 })

		let target = try #require(sut.shareTarget(for: displayID))
		sut.stopSharing(displayID: displayID)

		#expect(mock.disconnectTargetCallCount == 1)
		#expect(mock.disconnectedTargetsHistory == [Set([target])])
        #expect(sut.hasAnyActiveSharing == false)
    }

	@MainActor @Test func stopUnknownSharingDoesNotDisconnectUnrelatedTargets() {
		let mock = MockWebServiceController()
		let sut = makeService(webServiceController: mock)

		sut.stopSharing(displayID: CGDirectDisplayID(11))

		#expect(mock.disconnectTargetCallCount == 0)
	}

    @MainActor @Test func registerShareableDisplaysDisconnectsConnectionsForRemappedTargets() throws {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
        let displayID = CGDirectDisplayID(24)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)

        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })
        let originalTarget = try #require(sut.shareTarget(for: displayID))
        #expect(mock.disconnectTargetCallCount == 0)

        sut.registerShareableDisplays([display], virtualSerialResolver: { _ in 77 })

        #expect(mock.disconnectTargetCallCount == 1)
        #expect(mock.disconnectedTargetsHistory == [Set([originalTarget])])
        #expect(sut.shareTarget(for: displayID) == .id(77))
    }

    @MainActor @Test func stopWebServiceStopsControllerAndDisconnectsAllStreamClients() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)

        sut.stopWebService()

        #expect(mock.stopCallCount == 1)
        #expect(mock.disconnectCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func stopWebServiceStopsActiveSharingSessionsBeforeStoppingController() async throws {
        let mock = MockWebServiceController()
        let displayID = CGDirectDisplayID(21)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let cancelCounter = SharingServiceCounter()
        let sut = makeService(
            webServiceController: mock,
            acquireShare: { _, _ in
                .started(DisplayShareSubscription(
                    displayID: displayID,
                    shareFrameConsumer: TestSignalSessionHub(),
                    cancelClosure: { cancelCounter.increment() }
                ))
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })
        let outcome = try await sut.startSharing(display: display)
        guard case .started = outcome else {
            Issue.record("Expected sharing start to succeed.")
            return
        }

        sut.stopWebService()

        #expect(await waitUntil { cancelCounter.value == 1 })
        #expect(sut.hasAnyActiveSharing == false)
        #expect(mock.disconnectCallCount == 1)
        #expect(mock.stopCallCount == 1)
    }

    @MainActor @Test func failedWebServiceLifecycleStopsSharingAndResetsConnectionSnapshot() async throws {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        let aggregator = SharingStateAggregator()
        let displayID = CGDirectDisplayID(25)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let cancelCounter = SharingServiceCounter()
        let sut = makeService(
            webServiceController: mock,
            acquireShare: { _, _ in
                .started(DisplayShareSubscription(
                    displayID: displayID,
                    shareFrameConsumer: TestSignalSessionHub(),
                    cancelClosure: { cancelCounter.increment() }
                ))
            },
            sharingStateAggregator: aggregator
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })
        aggregator.record(
            sharingEvent(
                target: .main,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        var receivedStates: [WebServiceLifecycleState] = []
        sut.onWebServiceLifecycleStateChanged = { state in
            receivedStates.append(state)
        }

        let outcome = try await sut.startSharing(display: display)
        guard case .started = outcome else {
            Issue.record("Expected sharing start to succeed.")
            return
        }
        let failure = WebServiceLifecycleState.failed(
            .listenerFailed(port: requestedPort, message: "listener_failed")
        )

        mock.isRunning = false
        mock.lifecycleState = failure
        mock.onLifecycleStateChanged?(failure)

        #expect(await waitUntil { cancelCounter.value == 1 })
        #expect(sut.hasAnyActiveSharing == false)
        #expect(sut.activeSharingDisplayIDs.isEmpty)
        #expect(sut.activeStreamClientCount == 0)
        #expect(sut.sharingStateSnapshot == .empty)
        #expect(sut.webServiceLifecycleState == failure)
        #expect(receivedStates == [failure])
        #expect(mock.disconnectCallCount == 1)
        #expect(mock.stopCallCount == 0)
    }

    @MainActor @Test func stopWebServiceInvalidatesInFlightSharingStart() async throws {
        let mock = MockWebServiceController()
        let gate = SharingServiceAsyncGate()
        let displayID = CGDirectDisplayID(23)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let cancelCounter = SharingServiceCounter()
        let sut = makeService(
            webServiceController: mock,
            acquireShare: { _, _ in
                await gate.wait()
                return .started(DisplayShareSubscription(
                    displayID: displayID,
                    shareFrameConsumer: TestSignalSessionHub(),
                    cancelClosure: { cancelCounter.increment() }
                ))
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ -> UInt32? in nil })

        let task = Task { @MainActor in
            try await sut.startSharing(display: display)
        }

        #expect(await waitForSharingServiceGate(gate, count: 1))

        sut.stopWebService()

        #expect(await waitForSharingServiceTaskInvalidation(task))

        await gate.releaseOne()
        let outcome = try await task.value
        if case .invalidated = outcome {
        } else {
            Issue.record("Expected in-flight sharing start to be invalidated when the web service stops.")
        }

        #expect(await waitUntil { cancelCounter.value == 1 })
        #expect(sut.hasAnyActiveSharing == false)
        #expect(mock.disconnectCallCount == 1)
        #expect(mock.stopCallCount == 1)
    }

    @MainActor @Test func activeStreamClientCountReflectsSharingSnapshot() {
        let mock = MockWebServiceController()
        let aggregator = SharingStateAggregator()
        aggregator.record(
            sharingEvent(
                target: .main,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        aggregator.record(
            sharingEvent(
                target: .id(7),
                clientID: "client-2",
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        aggregator.record(
            sharingEvent(
                target: .id(7),
                clientID: "client-3",
                phase: .signalingConnected,
                source: .webSocket
            )
        )
        let sut = makeService(webServiceController: mock, sharingStateAggregator: aggregator)

        #expect(sut.activeStreamClientCount == 2)
        #expect(sut.streamClientCount(for: .id(7)) == 1)
        #expect(sut.sharingStateSnapshot.signalingConnections == 3)
    }

    @MainActor @Test func subscribeSharingStateImmediatelyReplaysCurrentSnapshot() {
        let mock = MockWebServiceController()
        let aggregator = SharingStateAggregator()
        aggregator.record(
            sharingEvent(
                target: .main,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        let sut = makeService(webServiceController: mock, sharingStateAggregator: aggregator)
        var snapshots: [SharingStateSnapshot] = []

        let subscription = sut.subscribeSharingState { snapshot in
            snapshots.append(snapshot)
        }

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.streamingPeers == 1)
        subscription.cancel()
    }

    @MainActor @Test func alreadyRunningStartPreservesCurrentSharingSnapshot() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.isRunning = true
        mock.lifecycleState = .running(.init(requestedPort: requestedPort, boundPort: requestedPort))
        mock.startResult = .alreadyRunning(
            WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        )
        let aggregator = SharingStateAggregator()
        aggregator.record(
            sharingEvent(
                target: .main,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        let sut = makeService(webServiceController: mock, sharingStateAggregator: aggregator)

        let result = await sut.startWebService(requestedPort: requestedPort)

        #expect(result == .alreadyRunning(.init(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(sut.sharingStateSnapshot.streamingPeers == 1)
        #expect(sut.sharingStateSnapshot.clientsByTarget[.main]?["client-1"] != nil)
    }

    @MainActor @Test func forwardsWebServiceLifecycleStateCallbackFromController() {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
        var receivedStates: [WebServiceLifecycleState] = []

        sut.onWebServiceLifecycleStateChanged = { state in
            receivedStates.append(state)
        }

        let binding = WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        mock.onLifecycleStateChanged?(.starting(requestedPort: requestedPort))
        mock.onLifecycleStateChanged?(.running(binding))
        mock.onLifecycleStateChanged?(.stopped)

        #expect(receivedStates == [
            .starting(requestedPort: requestedPort),
            .running(binding),
            .stopped
        ])
    }

    @MainActor
    private func makeService(
        webServiceController: MockWebServiceController,
        acquireShare: DisplaySharingCoordinator.AcquireShare? = nil,
        sharingStateAggregator: SharingStateAggregator = SharingStateAggregator()
    ) -> SharingService {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
        let idStore = DisplayShareIDStore(storeURL: storeURL)
        let coordinator: DisplaySharingCoordinator
        if let acquireShare {
            coordinator = DisplaySharingCoordinator(
                idStore: idStore,
                acquireShare: acquireShare
            )
        } else {
            coordinator = DisplaySharingCoordinator(idStore: idStore)
        }
        return SharingService(
            webServiceController: webServiceController,
            sharingCoordinator: coordinator,
            sharingStateAggregator: sharingStateAggregator
        )
    }
}

private func waitForSharingServiceGate(
    _ gate: SharingServiceAsyncGate,
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

private func waitForSharingServiceTaskInvalidation(
    _ task: Task<DisplayStartOutcome<Void>, Error>,
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000
) async -> Bool {
    let box = SharingServiceOutcomeBox()
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
