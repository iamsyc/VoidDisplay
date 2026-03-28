import Foundation
import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class SharingServiceDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        _ = showsCursor
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {}
}

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

private final class SharingServiceMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum SharingServiceMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = SharingServiceMockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
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

    @MainActor @Test func stopSingleSharingKeepsConnectionManagementInTargetHub() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)

        sut.stopSharing(displayID: CGDirectDisplayID(11))
        sut.stopSharing(displayID: CGDirectDisplayID(11))

        #expect(mock.disconnectCallCount == 0)
        #expect(sut.hasAnyActiveSharing == false)
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
        let display = SharingServiceMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let cancelCounter = SharingServiceCounter()
        let sut = makeService(
            webServiceController: mock,
            acquireShare: { _, _ in
                .started(DisplayShareSubscription(
                    displayID: displayID,
                    sessionHub: WebRTCSessionHub(),
                    session: SharingServiceDummySession(),
                    cancelClosure: { cancelCounter.increment() }
                ))
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ in nil })
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

    @MainActor @Test func stopWebServiceInvalidatesInFlightSharingStart() async throws {
        let mock = MockWebServiceController()
        let gate = SharingServiceAsyncGate()
        let displayID = CGDirectDisplayID(23)
        let display = SharingServiceMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let cancelCounter = SharingServiceCounter()
        let sut = makeService(
            webServiceController: mock,
            acquireShare: { _, _ in
                await gate.wait()
                return .started(DisplayShareSubscription(
                    displayID: displayID,
                    sessionHub: WebRTCSessionHub(),
                    session: SharingServiceDummySession(),
                    cancelClosure: { cancelCounter.increment() }
                ))
            }
        )
        sut.registerShareableDisplays([display], virtualSerialResolver: { _ in nil })

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

    @MainActor @Test func startSharingPropagatesDisplayNotRegisteredError() async {
        let displayID = CGDirectDisplayID(22)
        let display = SharingServiceMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sut = makeService(webServiceController: MockWebServiceController())

        do {
            _ = try await sut.startSharing(display: display)
            Issue.record("Expected displayNotRegistered error.")
        } catch let error as SharingStartError {
            #expect(error == .displayNotRegistered(displayID))
        } catch {
            Issue.record("Expected SharingStartError.displayNotRegistered, got \(error)")
        }
    }

    @MainActor @Test func activeStreamClientCountReflectsSharingSnapshot() {
        let mock = MockWebServiceController()
        let aggregator = SharingStateAggregator()
        aggregator.record(
            SharingSessionEvent(
                target: .main,
                clientID: "client-1",
                sequence: 1,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        aggregator.record(
            SharingSessionEvent(
                target: .id(7),
                clientID: "client-2",
                sequence: 1,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        aggregator.record(
            SharingSessionEvent(
                target: .id(7),
                clientID: "client-3",
                sequence: 1,
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
            SharingSessionEvent(
                target: .main,
                clientID: "client-1",
                sequence: 1,
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

    @MainActor @Test func closedClientIsRemovedFromCurrentSnapshot() {
        let aggregator = SharingStateAggregator()
        aggregator.record(
            SharingSessionEvent(
                target: .id(7),
                clientID: "client-1",
                sequence: 1,
                phase: .peerConnected,
                source: .peerConnection
            )
        )
        aggregator.record(
            SharingSessionEvent(
                target: .id(7),
                clientID: "client-1",
                sequence: 2,
                phase: .closed,
                source: .webSocket
            )
        )
        aggregator.record(
            SharingSessionEvent(
                target: .id(7),
                clientID: "client-1",
                sequence: 1,
                phase: .peerDisconnected,
                source: .peerConnection
            )
        )

        let snapshot = aggregator.currentSnapshot
        #expect(snapshot.signalingConnections == 0)
        #expect(snapshot.streamingPeers == 0)
        #expect(snapshot.clientsByTarget[.id(7)]?.isEmpty ?? true)
        #expect(snapshot.lastUpdatedAt != nil)
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
            SharingSessionEvent(
                target: .main,
                clientID: "client-1",
                sequence: 1,
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

    @MainActor @Test func forwardsWebServiceRunningStateCallbackFromController() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        mock.onRunningStateChanged?(true)
        mock.onRunningStateChanged?(false)

        #expect(receivedStates == [true, false])
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

    @MainActor @Test func startAndStopEmitRunningStateChanges() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .started(
            WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        )
        let sut = makeService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        #expect(await sut.startWebService(requestedPort: requestedPort) == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        sut.stopWebService()

        #expect(receivedStates == [true, false])
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
        let coordinator = DisplaySharingCoordinator(
            idStore: idStore,
            acquireShare: acquireShare
        )
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
