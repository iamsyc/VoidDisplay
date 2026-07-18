@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharingTestingSupport
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Security
import Testing

private final class DisplaySharingCoordinatorDummyShare: @unchecked Sendable {
    nonisolated let sessionHub = TestSignalSessionHub()

    private let retainGate: DisplaySharingCoordinatorAsyncGate?
    private let releaseCounter: DisplaySharingCoordinatorCounter?

    init(
        retainGate: DisplaySharingCoordinatorAsyncGate? = nil,
        releaseCounter: DisplaySharingCoordinatorCounter? = nil
    ) {
        self.retainGate = retainGate
        self.releaseCounter = releaseCounter
    }

    nonisolated func prepareForSharing() async throws {
        await retainGate?.wait()
    }

    nonisolated func releasePreparedShare() async {
        releaseCounter?.increment()
    }
}

private final class DisplaySharingCoordinatorCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0

    nonisolated func increment() {
        value += 1
    }
}

private actor DisplaySharingCoordinatorAsyncGate {
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

private actor DisplaySharingCoordinatorOutcomeBox {
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

@Suite(.serialized)
struct DisplaySharingCoordinatorTests {
    @MainActor
    @Test func virtualDisplaysUseDenseShareIDsWithoutPhysicalOffset() throws {
        let storeURL = temporaryStoreURL()
        let store = DisplayShareIDStore(storeURL: storeURL)
        let coordinator = DisplaySharingCoordinator(idStore: store)

        // Simulate a pre-existing physical mapping that previously consumed share ID 1.
        #expect(store.assignID(for: "physical:mock-main", excluding: []) == 1)

        let physicalMain: CGDirectDisplayID = 100
        let virtualA: CGDirectDisplayID = 200
        let virtualB: CGDirectDisplayID = 300

        coordinator.registerShareableDisplays([
            .init(displayID: physicalMain, isMain: true, virtualSerial: nil),
            .init(displayID: virtualA, isMain: false, virtualSerial: 1),
            .init(displayID: virtualB, isMain: false, virtualSerial: 3)
        ])

        #expect(coordinator.shareID(for: virtualA) == 1)
        #expect(coordinator.shareID(for: virtualB) == 3)

        let physicalShareID = try #require(coordinator.shareID(for: physicalMain))
        #expect(!Set([UInt32(1), UInt32(3)]).contains(physicalShareID))
    }

    @MainActor
    @Test func physicalDisplayShareIDStaysStableAcrossReorderedRegistration() throws {
        let store = DisplayShareIDStore(storeURL: temporaryStoreURL())
        let coordinator = DisplaySharingCoordinator(idStore: store)
        let firstMain: CGDirectDisplayID = 101
        let secondPhysical: CGDirectDisplayID = 102

        coordinator.registerShareableDisplays([
            .init(displayID: firstMain, isMain: true, virtualSerial: nil),
            .init(displayID: secondPhysical, isMain: false, virtualSerial: nil)
        ])
        let initialMainID = try #require(coordinator.shareID(for: firstMain))
        let initialSecondaryID = try #require(coordinator.shareID(for: secondPhysical))

        coordinator.registerShareableDisplays([
            .init(displayID: secondPhysical, isMain: false, virtualSerial: nil),
            .init(displayID: firstMain, isMain: true, virtualSerial: nil)
        ])

        #expect(coordinator.shareID(for: firstMain) == initialMainID)
        #expect(coordinator.shareID(for: secondPhysical) == initialSecondaryID)
    }

    @MainActor
    @Test func removingRegisteredDisplayStopsActiveSharingSession() async throws {
        let displayID: CGDirectDisplayID = 103
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let subscription = makeSubscription(displayID: displayID)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in .started(subscription.subscription) }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let startOutcome = try await coordinator.startSharing(display: display)
        guard case .started = startOutcome else {
            Issue.record("Expected sharing start to succeed.")
            return
        }
        coordinator.registerShareableDisplays([])

        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func startSharingFailsForUnregisteredDisplay() async {
        let displayID: CGDirectDisplayID = 104
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let coordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))

        do {
            let outcome = try await coordinator.startSharing(display: display)
            Issue.record("Expected displayNotRegistered error, got \(outcome).")
        } catch let error as SharingStartError {
            #expect(error == .displayNotRegistered(displayID))
        } catch {
            Issue.record("Expected SharingStartError.displayNotRegistered, got \(error)")
        }

        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func startSharingInvalidatesImmediatelyWhenRegistrationChangesDuringAcquire() async {
        let displayID: CGDirectDisplayID = 205
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let acquireGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: displayID)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in
                await acquireGate.wait()
                return .started(subscription.subscription)
            }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let task = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForGate(acquireGate, count: 1))

        coordinator.registerShareableDisplays([])
        let invalidatedBeforeGateRelease = await waitForTaskInvalidation(task)
        #expect(invalidatedBeforeGateRelease)

        await acquireGate.releaseOne()
        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func startSharingCancelsSubscriptionWhenRegistrationChangesDuringPrepare() async {
        let displayID: CGDirectDisplayID = 106
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let prepareGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: displayID, retainGate: prepareGate)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in .started(subscription.subscription) }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let task = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForGate(prepareGate, count: 1))

        coordinator.registerShareableDisplays([])
        let outcome = try? await task.value
        if case .some(.invalidated) = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }

        await prepareGate.releaseOne()
        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func startSharingSucceedsWhenRegistrationRefreshKeepsSameDisplay() async throws {
        let targetDisplayID: CGDirectDisplayID = 107
        let otherDisplayID: CGDirectDisplayID = 108
        let targetDisplay = SharedMockSCDisplay.make(
            displayID: targetDisplayID,
            width: 1920,
            height: 1080
        )
        let acquireGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: targetDisplayID)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in
                await acquireGate.wait()
                return .started(subscription.subscription)
            }
        )
        coordinator.registerShareableDisplays([
            .init(displayID: targetDisplayID, isMain: true, virtualSerial: nil),
            .init(displayID: otherDisplayID, isMain: false, virtualSerial: nil)
        ])

        let task = Task { @MainActor in
            try await coordinator.startSharing(display: targetDisplay)
        }
        #expect(await waitForGate(acquireGate, count: 1))

        coordinator.registerShareableDisplays([
            .init(displayID: otherDisplayID, isMain: false, virtualSerial: nil),
            .init(displayID: targetDisplayID, isMain: true, virtualSerial: nil)
        ])
        await acquireGate.releaseOne()

        let outcome = try await task.value
        guard case .started = outcome else {
            Issue.record("Expected sharing start to succeed after registration refresh.")
            return
        }

        #expect(coordinator.isSharing(displayID: targetDisplayID))
        #expect(subscription.cancelCounter.value == 0)

        coordinator.stopAllSharing()
        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
    }

    @MainActor
    @Test func concurrentStartSharingForSameDisplayAcquiresShareOnlyOnce() async throws {
        let displayID: CGDirectDisplayID = 111
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let acquireGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: displayID)
        let startCoordinator = DisplayStreamStartCoordinator()
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            startCoordinator: startCoordinator,
            acquireShare: { _, _ in
                await acquireGate.wait()
                return .started(subscription.subscription)
            }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let firstTask = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForGate(acquireGate, count: 1))

        let secondTask = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForCoordinatorWaiters(
            startCoordinator,
            kind: .sharing,
            displayID: displayID,
            count: 2
        ))
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedSecondAcquire = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await acquireGate.currentWaitCount() > 1 {
                observedSecondAcquire = true
                break
            }
            await Task.yield()
        }
        #expect(observedSecondAcquire == false)

        await acquireGate.releaseOne()

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

        #expect(coordinator.isSharing(displayID: displayID))
        #expect(subscription.cancelCounter.value == 0)

        coordinator.stopAllSharing()
        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
    }

    @MainActor
    @Test func stopAllSharingInvalidatesInFlightStartDuringAcquire() async throws {
        let displayID: CGDirectDisplayID = 112
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let acquireGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: displayID)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in
                await acquireGate.wait()
                return .started(subscription.subscription)
            }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let task = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForGate(acquireGate, count: 1))

        coordinator.stopAllSharing()

        #expect(await waitForTaskInvalidation(task))

        await acquireGate.releaseOne()
        let outcome = try await task.value
        if case .invalidated = outcome {
        } else {
            Issue.record("Expected in-flight sharing start to be invalidated by stopAllSharing.")
        }

        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func stopAllSharingPreventsStaleSessionWriteWhenPrepareResumesAfterInvalidation() async throws {
        let displayID: CGDirectDisplayID = 113
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let prepareGate = DisplaySharingCoordinatorAsyncGate()
        let subscription = makeSubscription(displayID: displayID, retainGate: prepareGate)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in .started(subscription.subscription) }
        )
        coordinator.registerShareableDisplays([.init(displayID: displayID, isMain: true, virtualSerial: nil)])

        let task = Task { @MainActor in
            try await coordinator.startSharing(display: display)
        }
        #expect(await waitForGate(prepareGate, count: 1))

        coordinator.stopAllSharing()
        #expect(await waitForTaskInvalidation(task))

        await prepareGate.releaseOne()
        let outcome = try await task.value
        if case .invalidated = outcome {
        } else {
            Issue.record("Expected sharing start to stay invalidated after stopAllSharing.")
        }

        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
    }

    @MainActor
    @Test func mainTargetContractIsActiveOrKnownInactiveAndHubIsNilWhenUnresolved() async throws {
        let unresolvedCoordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))
        #expect(unresolvedCoordinator.state(for: ShareTarget.main) == .knownInactive)
        #expect(unresolvedCoordinator.sessionHub(for: ShareTarget.main) == nil)

        let inactiveCoordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))
        inactiveCoordinator.registerShareableDisplays([.init(displayID: 109, isMain: true, virtualSerial: nil)])
        #expect(inactiveCoordinator.state(for: ShareTarget.main) == .knownInactive)
        #expect(inactiveCoordinator.sessionHub(for: ShareTarget.main) == nil)

        let activeSubscription = makeSubscription(displayID: 110)
        let activeCoordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in .started(activeSubscription.subscription) }
        )
        let display = SharedMockSCDisplay.make(displayID: 110, width: 1920, height: 1080)
        activeCoordinator.registerShareableDisplays([.init(displayID: 110, isMain: true, virtualSerial: nil)])
        let outcome = try await activeCoordinator.startSharing(display: display)
        guard case .started = outcome else {
            Issue.record("Expected active sharing start to succeed.")
            return
        }

        #expect(activeCoordinator.state(for: ShareTarget.main) == .active)
        let hub = try #require(activeCoordinator.sessionHub(for: ShareTarget.main))
        #expect(ObjectIdentifier(hub) == ObjectIdentifier(activeSubscription.share.sessionHub))

        activeCoordinator.stopAllSharing()
        #expect(await waitUntil { activeSubscription.cancelCounter.value == 1 })
    }

    @MainActor
    @Test func resolveConcreteTargetMapsMainAliasAndRejectsUnknownTargets() {
        let coordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))
        coordinator.registerShareableDisplays([
            .init(displayID: 201, isMain: true, virtualSerial: nil),
            .init(displayID: 202, isMain: false, virtualSerial: nil)
        ])

        guard let mainShareID = coordinator.shareID(for: 201),
              let secondaryShareID = coordinator.shareID(for: 202) else {
            Issue.record("Expected registered displays to receive concrete share IDs.")
            return
        }

        #expect(coordinator.resolveConcreteTarget(for: .main) == .id(mainShareID))
        #expect(coordinator.resolveConcreteTarget(for: .id(mainShareID)) == .id(mainShareID))
        #expect(coordinator.resolveConcreteTarget(for: .id(secondaryShareID)) == .id(secondaryShareID))
        #expect(coordinator.resolveConcreteTarget(for: .id(999_999)) == nil)

        let unresolvedCoordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))
        #expect(unresolvedCoordinator.resolveConcreteTarget(for: .main) == nil)
    }

    @MainActor
    @Test func registerShareableDisplaysReturnsPriorConcreteTargetWhenShareIDChanges() throws {
        let displayID: CGDirectDisplayID = 301
        let coordinator = DisplaySharingCoordinator(idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()))

        let initialInvalidatedTargets = coordinator.registerShareableDisplays([
            .init(displayID: displayID, isMain: true, virtualSerial: nil)
        ])
        let originalTarget = try #require(coordinator.target(for: displayID))

        let remappedTargets = coordinator.registerShareableDisplays([
            .init(displayID: displayID, isMain: true, virtualSerial: 77)
        ])

        #expect(initialInvalidatedTargets.isEmpty)
        #expect(remappedTargets == Set([originalTarget]))
        #expect(coordinator.target(for: displayID) == .id(77))
    }

    @MainActor
    @Test func shareAccessCapabilityRotatesOnRestartAndStopsAuthorizingImmediately() async throws {
        let displayID: CGDirectDisplayID = 302
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let firstSubscription = makeSubscription(displayID: displayID)
        let secondSubscription = makeSubscription(displayID: displayID)
        let firstCapability = try #require(ShareAccessCapability(
            pathComponent: String(repeating: "b", count: ShareAccessCapability.pathComponentLength)
        ))
        let secondCapability = try #require(ShareAccessCapability(
            pathComponent: String(repeating: "c", count: ShareAccessCapability.pathComponentLength)
        ))
        var acquireCount = 0
        var capabilityCount = 0
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in
                defer { acquireCount += 1 }
                return .started(acquireCount == 0 ? firstSubscription.subscription : secondSubscription.subscription)
            },
            accessCapabilityGenerator: {
                defer { capabilityCount += 1 }
                return capabilityCount == 0 ? firstCapability : secondCapability
            }
        )
        coordinator.registerShareableDisplays([
            .init(displayID: displayID, isMain: true, virtualSerial: 9)
        ])

        #expect(coordinator.sharePagePath(for: displayID) == nil)
        #expect(coordinator.validatesAccess(to: .main, capability: firstCapability) == false)

        guard case .started = try await coordinator.startSharing(display: display) else {
            Issue.record("Expected first sharing start to succeed.")
            return
        }
        #expect(
            coordinator.sharePagePath(for: displayID)
                == ShareTarget.id(9).displayPath(accessCapability: firstCapability)
        )
        #expect(coordinator.validatesAccess(to: .main, capability: firstCapability))
        #expect(coordinator.validatesAccess(to: .id(9), capability: firstCapability))
        #expect(coordinator.validatesAccess(to: .id(9), capability: secondCapability) == false)

        coordinator.stopSharing(displayID: displayID)
        #expect(coordinator.sharePagePath(for: displayID) == nil)
        #expect(coordinator.validatesAccess(to: .id(9), capability: firstCapability) == false)

        guard case .started = try await coordinator.startSharing(display: display) else {
            Issue.record("Expected restarted sharing session to succeed.")
            return
        }
        #expect(
            coordinator.sharePagePath(for: displayID)
                == ShareTarget.id(9).displayPath(accessCapability: secondCapability)
        )
        #expect(coordinator.validatesAccess(to: .id(9), capability: firstCapability) == false)
        #expect(coordinator.validatesAccess(to: .id(9), capability: secondCapability))

        coordinator.stopAllSharing()
        #expect(await waitUntil {
            firstSubscription.cancelCounter.value == 1
                && secondSubscription.cancelCounter.value == 1
        })
    }

    @MainActor
    @Test func capabilityGenerationFailureCancelsPreparedSubscription() async throws {
        let displayID: CGDirectDisplayID = 303
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let subscription = makeSubscription(displayID: displayID)
        let expectedError = ShareAccessCapabilityGenerationError.entropyUnavailable(errSecNotAvailable)
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: temporaryStoreURL()),
            acquireShare: { _, _ in .started(subscription.subscription) },
            accessCapabilityGenerator: { throw expectedError }
        )
        coordinator.registerShareableDisplays([
            .init(displayID: displayID, isMain: true, virtualSerial: 10)
        ])

        do {
            _ = try await coordinator.startSharing(display: display)
            Issue.record("Expected capability generation failure.")
        } catch let error as ShareAccessCapabilityGenerationError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await waitUntil { subscription.cancelCounter.value == 1 })
        #expect(coordinator.isSharing(displayID: displayID) == false)
        #expect(coordinator.sharePagePath(for: displayID) == nil)
    }

    private func temporaryStoreURL() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-sharing-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        return base.appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
    }

    private func makeSubscription(
        displayID: CGDirectDisplayID,
        retainGate: DisplaySharingCoordinatorAsyncGate? = nil
    ) -> (
        subscription: DisplayShareSubscription,
        share: DisplaySharingCoordinatorDummyShare,
        cancelCounter: DisplaySharingCoordinatorCounter
    ) {
        let cancelCounter = DisplaySharingCoordinatorCounter()
        let releaseCounter = DisplaySharingCoordinatorCounter()
        let share = DisplaySharingCoordinatorDummyShare(
            retainGate: retainGate,
            releaseCounter: releaseCounter
        )
        let subscription = DisplayShareSubscription(
            displayID: displayID,
            shareFrameConsumer: share.sessionHub,
            cancelClosure: { cancelCounter.increment() },
            prepareForSharingClosure: {
                try await share.prepareForSharing()
            },
            releasePreparedShareClosure: {
                await share.releasePreparedShare()
            }
        )
        return (subscription, share, cancelCounter)
    }

    private func waitForGate(
        _ gate: DisplaySharingCoordinatorAsyncGate,
        count: Int
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentWaitCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentWaitCount() >= count
    }

    private func waitForTaskInvalidation(
        _ task: Task<DisplayStartOutcome<Void>, Error>
    ) async -> Bool {
        let box = DisplaySharingCoordinatorOutcomeBox()
        Task {
            guard let outcome = try? await task.value else { return }
            await box.store(outcome)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await box.isInvalidated() {
                return true
            }
            await Task.yield()
        }
        return await box.isInvalidated()
    }

    private func waitForCoordinatorWaiters(
        _ coordinator: DisplayStreamStartCoordinator,
        kind: DisplayStartKind,
        displayID: CGDirectDisplayID,
        count: Int
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await MainActor.run(body: {
                coordinator.waiterCountForTesting(kind: kind, displayID: displayID) >= count
            }) {
                return true
            }
            await Task.yield()
        }
        return await MainActor.run(body: {
            coordinator.waiterCountForTesting(kind: kind, displayID: displayID) >= count
        })
    }
}
