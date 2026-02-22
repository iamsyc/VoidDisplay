import Foundation

struct RebuildPresentationState {
    private(set) var rebuildingConfigIds: Set<UUID> = []
    private(set) var rebuildFailureMessageByConfigId: [UUID: String] = [:]
    private(set) var recentlyAppliedConfigIds: Set<UUID> = []

    mutating func beginRebuild(configId: UUID) {
        rebuildFailureMessageByConfigId.removeValue(forKey: configId)
        recentlyAppliedConfigIds.remove(configId)
        rebuildingConfigIds.insert(configId)
    }

    mutating func finishRebuild(configId: UUID) {
        rebuildingConfigIds.remove(configId)
    }

    mutating func markRebuildSuccess(configId: UUID) {
        rebuildFailureMessageByConfigId.removeValue(forKey: configId)
        recentlyAppliedConfigIds.insert(configId)
    }

    mutating func markRebuildFailure(configId: UUID, message: String) {
        rebuildFailureMessageByConfigId[configId] = message
        recentlyAppliedConfigIds.remove(configId)
    }

    mutating func clearRecentApply(configId: UUID) {
        recentlyAppliedConfigIds.remove(configId)
    }

    mutating func clear(configId: UUID) {
        rebuildingConfigIds.remove(configId)
        rebuildFailureMessageByConfigId.removeValue(forKey: configId)
        recentlyAppliedConfigIds.remove(configId)
    }

    func allConfigIds(extra: Set<UUID> = []) -> Set<UUID> {
        extra
            .union(rebuildingConfigIds)
            .union(Set(rebuildFailureMessageByConfigId.keys))
            .union(recentlyAppliedConfigIds)
    }
}
