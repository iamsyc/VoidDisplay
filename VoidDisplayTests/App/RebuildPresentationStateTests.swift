import Testing
@testable import VoidDisplay

struct RebuildPresentationStateTests {

    @Test func beginAndFinishRebuildUpdatesRunningSet() {
        var state = RebuildPresentationState()
        let id = UUID()

        state.beginRebuild(configId: id)
        #expect(state.rebuildingConfigIds.contains(id))

        state.finishRebuild(configId: id)
        #expect(state.rebuildingConfigIds.contains(id) == false)
    }

    @Test func successAndFailureMutateBadgesAndMessages() {
        var state = RebuildPresentationState()
        let id = UUID()

        state.beginRebuild(configId: id)
        state.markRebuildSuccess(configId: id)
        #expect(state.rebuildFailureMessageByConfigId[id] == nil)
        #expect(state.recentlyAppliedConfigIds.contains(id))

        state.markRebuildFailure(configId: id, message: "failed")
        #expect(state.rebuildFailureMessageByConfigId[id] == "failed")
        #expect(state.recentlyAppliedConfigIds.contains(id) == false)
    }

    @Test func clearAndAllConfigIdsIncludeEveryBucket() {
        var state = RebuildPresentationState()
        let a = UUID()
        let b = UUID()
        let c = UUID()

        state.beginRebuild(configId: a)
        state.markRebuildFailure(configId: b, message: "oops")
        state.markRebuildSuccess(configId: c)

        let all = state.allConfigIds(extra: [UUID()])
        #expect(all.contains(a))
        #expect(all.contains(b))
        #expect(all.contains(c))

        state.clear(configId: b)
        #expect(state.rebuildFailureMessageByConfigId[b] == nil)
    }
}
