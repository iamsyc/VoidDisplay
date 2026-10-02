@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
struct DisplayRuntimeEnabledSetApplicationTests {
    @Test func enablesBeforeDisablingAndSynchronizesBeforeReleasingBusyState() async throws {
        let fixture = EnabledSetFixture()
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        var settled: [Set<UUID>] = []
        let result = try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {
            #expect(fixture.runtime.isApplyingVirtualDisplayEnabledSet)
            settled.append(Set(fixture.runtime.makeSnapshot().virtualDisplay.runningConfigIDs))
        }
        #expect(result.status == .completed)
        #expect(fixture.commands == ["enable", "disable"])
        #expect(settled == [Set([fixture.a, fixture.b]), Set([fixture.b]), Set([fixture.b])])
        #expect(!fixture.runtime.isApplyingVirtualDisplayEnabledSet)
        #expect(fixture.runtime.makeSnapshot().enabledSetApplication == nil)
        let trace = try #require(fixture.runtime.makeSnapshot().transactions.recentTransactions.first)
        #expect(trace.enabledSetResult == result)
        #expect(result.steps.count == 2)
    }

    @Test func enableFailureKeepsPersistedIntentAndNeverDisablesExistingDisplay() async throws {
        let fixture = EnabledSetFixture()
        fixture.commander.enableError = NSError(domain: "injected", code: 1)
        var synchronizedIntent = Set<UUID>()
        let result = try await fixture.runtime.applyVirtualDisplayEnabledSet(
            plan: fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b]), source: .displaySceneApply
        ) {
            synchronizedIntent = Set(fixture.runtime.makeSnapshot().virtualDisplay.configs.filter(\.desiredEnabled).map(\.id))
        }
        #expect(result.status == .failed)
        #expect(synchronizedIntent == [fixture.a, fixture.b])
        #expect(fixture.commander.disableCallCount == 0)
        #expect(result.skippedSteps.map(\.configID) == [fixture.a])
        #expect(result.finalState.runningConfigIDs == [fixture.a])
        #expect(!fixture.runtime.isApplyingVirtualDisplayEnabledSet)
        fixture.commander.enableError = nil
        let retry = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        let retried = try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: retry, source: .displaySceneApply) {}
        #expect(retried.status == .completed)
        #expect(fixture.runtime.makeSnapshot().latestFailure != nil)
    }

    @Test func stalePlanSettlesWithoutWriting() async throws {
        let fixture = EnabledSetFixture()
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        fixture.desired.insert(fixture.b)
        fixture.publish()
        var settled = false
        await #expect(throws: DisplayRuntimeEnabledSetError.stalePlan) {
            try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {
                #expect(fixture.runtime.isApplyingVirtualDisplayEnabledSet)
                settled = true
            }
        }
        #expect(settled)
        #expect(fixture.commands.isEmpty)
        #expect(fixture.commander.setDesiredEnabledRequests.isEmpty)
        #expect(!fixture.runtime.isApplyingVirtualDisplayEnabledSet)
    }

    @Test func unchangedCombinationAndEmptyRestoreAvoidUnnecessaryCommands() async throws {
        let fixture = EnabledSetFixture()
        let unchanged = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.a])
        #expect(unchanged.steps.isEmpty)
        let result = try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: unchanged, source: .displaySceneApply) {}
        #expect(result.status == .completed)
        #expect(fixture.commands.isEmpty)
        let empty = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [])
        let restored = try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: empty, source: .displaySceneApply) {}
        #expect(restored.status == .completed)
        #expect(restored.finalState.runningConfigIDs.isEmpty)
    }

    @Test func consumerRecoveryFailureStopsBeforeDisablingExistingDisplays() async throws {
        let fixture = EnabledSetFixture()
        fixture.captureCommander = FakeCaptureIntentCommander { intent in
            if intent.kind == .capture, intent.reason == .epochChanged {
                return .failed(revision: intent.revision, failureCode: "display_not_found")
            }
            return .applied(revision: intent.revision)
        }
        fixture.sharingProvider = FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 101))
        fixture.commander.enablePreflight = .init(configID: fixture.b, targetPreDisplayID: nil,
            mayPerformFleetRebuild: true, requiresFleetQuiesce: true, scopeEscalationReason: .enableMayPerformFleetRebuild)
        _ = await attachConsumerForTesting(fixture.runtime, surfaceIdentity: .managedVirtualDisplay(configID: fixture.a),
            kind: .lanWebView, owner: .init(source: .runtimeTest), demand: runtimeConsumerDemand())
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        #expect(plan.interruptedConfigIDs == [fixture.a])
        let result = try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {}
        #expect(result.status == .completedWithRecoveryFailures)
        #expect(fixture.commander.disableCallCount == 0)
        #expect(result.steps.first?.result.hasSessionRecoveryFailures == true)
    }

    @Test func changedConsumerInvalidatesAPlanBeforeCommands() async throws {
        let fixture = EnabledSetFixture()
        fixture.captureCommander = FakeCaptureIntentCommander()
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        _ = await attachConsumerForTesting(fixture.runtime, surfaceIdentity: .managedVirtualDisplay(configID: fixture.a),
            kind: .preview, owner: .init(source: .runtimeTest), demand: runtimeConsumerDemand())
        await #expect(throws: DisplayRuntimeEnabledSetError.stalePlan) {
            try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {}
        }
        #expect(fixture.commands.isEmpty)
    }

    @Test func missingReferenceRejectsTheEntirePlan() {
        let fixture = EnabledSetFixture()
        #expect(throws: DisplayRuntimeEnabledSetError.missingConfiguration) {
            try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b, UUID()])
        }
        #expect(fixture.commands.isEmpty)
    }

    @Test func disableFailureStopsRemainingStepsAndPublishesChangedIntent() async throws {
        let fixture = EnabledSetFixture()
        fixture.desired = [fixture.a, fixture.b]
        fixture.running = [fixture.a, fixture.b]
        fixture.publish()
        fixture.commander.disableError = NSError(domain: "injected", code: 2)
        var settledIntent = Set<UUID>()
        let result = try await fixture.runtime.applyVirtualDisplayEnabledSet(
            plan: fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: []), source: .displaySceneApply
        ) {
            #expect(fixture.runtime.isApplyingVirtualDisplayEnabledSet)
            settledIntent = Set(fixture.runtime.makeSnapshot().virtualDisplay.configs.filter(\.desiredEnabled).map(\.id))
        }
        #expect(result.status == .failed)
        #expect(fixture.commander.disableCallCount == 1)
        #expect(settledIntent == [fixture.b])
        #expect(result.skippedSteps.map(\.configID) == [fixture.b])
        #expect(Set(result.finalState.runningConfigIDs) == [fixture.a, fixture.b])
        #expect(!fixture.runtime.isApplyingVirtualDisplayEnabledSet)
    }

    @Test func precedingQueuedCommandInvalidatesPlanBeforeAnyBatchWrites() async throws {
        let fixture = EnabledSetFixture()
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        fixture.catalog.shouldGateSubmitRefresh = true
        let ordinary = Task { try await fixture.runtime.setVirtualDisplayDesiredEnabled(configID: fixture.b, enabled: true, source: .virtualDisplayRowToggle) }
        await fixture.catalog.waitForSubmitCalls(1)
        let batch = Task { try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {} }
        while !fixture.runtime.isApplyingVirtualDisplayEnabledSet { await Task.yield() }
        fixture.catalog.shouldGateSubmitRefresh = false
        fixture.catalog.releaseSubmitRefresh(call: 1)
        #expect(try await ordinary.value.status == .completed)
        await #expect(throws: DisplayRuntimeEnabledSetError.stalePlan) { try await batch.value }
        #expect(fixture.commander.setDesiredEnabledRequests.count == 1)
        #expect(fixture.commands == ["enable"])
        #expect(!fixture.runtime.isApplyingVirtualDisplayEnabledSet)
    }

    @Test func simultaneousBatchIsRejectedWhileOrdinaryCommandQueuesAfterTheBatch() async throws {
        let fixture = EnabledSetFixture()
        fixture.catalog.shouldGateSubmitRefresh = true
        let plan = try fixture.runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [fixture.b])
        let first = Task { try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {} }
        await fixture.catalog.waitForSubmitCalls(1)
        await #expect(throws: DisplayRuntimeEnabledSetError.alreadyApplying) {
            try await fixture.runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) {}
        }
        let ordinary = Task { try await fixture.runtime.setVirtualDisplayDesiredEnabled(configID: fixture.a, enabled: true, source: .virtualDisplayRowToggle) }
        fixture.catalog.shouldGateSubmitRefresh = false
        fixture.catalog.releaseSubmitRefresh(call: 1)
        #expect(try await first.value.status == .completed)
        #expect(try await ordinary.value.status == .completed)
        #expect(fixture.commands == ["enable", "disable", "enable"])
    }
}

@MainActor
private final class EnabledSetFixture {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var desired: Set<UUID> = []
    var running: Set<UUID> = []
    var commands: [String] = []
    var captureCommander: FakeCaptureIntentCommander?
    var sharingProvider: FakeSharingProvider?
    let provider = FakeVirtualDisplayProvider(snapshot: .empty)
    let commander = FakeVirtualDisplayCommander()
    let catalog = FakeCatalogCommander(snapshot: catalogSnapshot(displayIDs: [101, 102], mainDisplayID: nil))
    lazy var runtime = DisplayRuntime(
        catalogProvider: catalog, sharingProvider: sharingProvider, virtualDisplayProvider: provider, catalogCommander: catalog,
        captureIntentCommander: captureCommander,
        virtualDisplayCommander: commander, topologyWaitPolicy: fastTopologyWaitPolicy()
    )
    init() {
        desired = [a]; running = [a]; publish()
        commander.onSetDesiredEnabled = { [unowned self] id, enabled in
            if enabled { desired.insert(id) } else { desired.remove(id) }
            publish()
        }
        commander.onEnable = { [unowned self] id in running.insert(id); commands.append("enable"); publish() }
        commander.onDisable = { [unowned self] id in running.remove(id); commands.append("disable"); publish() }
    }
    func publish() {
        provider.setSnapshot(.init(
            runningConfigIDs: Array(running), configStoreHasLoadFailure: false, configStoreHasDiagnostics: false,
            managedDisplays: [a, b].filter(running.contains).map {
                .init(configID: $0, serialNumber: $0 == a ? 101 : 102, displayID: $0 == a ? 101 : 102, isLiveRuntime: true)
            },
            configs: [a, b].map {
                .init(id: $0, serialNumber: $0 == a ? 101 : 102, desiredEnabled: desired.contains($0),
                    physicalWidthMillimeters: 600, physicalHeightMillimeters: 340,
                    modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                    maximumPixelWidth: 1920, maximumPixelHeight: 1080)
            }, restoreFailureConfigIDs: []
        ))
    }
}
